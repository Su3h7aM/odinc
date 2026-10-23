package check

import "core:fmt"
import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
atomic_operation :: proc(kind: Builtin_Kind) -> (atomic, writes: bool) {
	#partial switch kind {
	case .Atomic_Load, .Atomic_Load_Explicit:
		return true, false
	case .Atomic_Store,
	     .Atomic_Store_Explicit,
	     .Atomic_Add,
	     .Atomic_Sub,
	     .Atomic_And,
	     .Atomic_Nand,
	     .Atomic_Or,
	     .Atomic_Xor,
	     .Atomic_Exchange,
	     .Atomic_Add_Explicit,
	     .Atomic_Sub_Explicit,
	     .Atomic_And_Explicit,
	     .Atomic_Nand_Explicit,
	     .Atomic_Or_Explicit,
	     .Atomic_Xor_Explicit,
	     .Atomic_Exchange_Explicit,
	     .Atomic_Compare_Exchange_Strong,
	     .Atomic_Compare_Exchange_Weak,
	     .Atomic_Compare_Exchange_Strong_Explicit,
	     .Atomic_Compare_Exchange_Weak_Explicit:
		return true, true
	}
	return false, false
}

// The official check_atomic_ptr_argument: the pointee must be a lock-free atomic type, and an address `&x` must not be
// within a #packed struct, less aligned than the pointee, or written while it is @(rodata).
@(private = "package")
atomic_pointer_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin_name: string,
	element: types.Type_Id,
	writes: bool,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	file_id := checker.views[view].file
	file := checker.type_checker.files[file_id]
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	core_type := conversion_core_type(store, element)
	kind := types.get(store, core_type).kind
	if !atomic_valid_kind(kind) {
		reason := fmt.aprintf("Only an integer, floating-point, boolean, or pointer can be used as an atomic for '%s'", builtin_name, allocator = allocator)
		atomic_report(checker, file_id, node, reason) or_return
		return false, nil
	}
	size, align, layout_error := types.layout(store, core_type)
	if layout_error != .None { return true, nil }
	_, has_cx16 := target_features_satisfied(types.x86_level_features(checker.microarch), "cx16")
	if size > (16 if has_cx16 else 8) || size & (size - 1) != 0 || align < size {
		reason := fmt.aprintf(
			"'%s' cannot be used as an atomic for '%s' on this target, as it is not lock-free",
			types.type_text(store, element, allocator),
			builtin_name,
			allocator = allocator,
		)
		if size ==
		   16 { reason = fmt.aprintf("%s\n\tSuggestion: A 16 byte atomic needs 'cx16', e.g. with --mcpu x86_64_v2 or later", reason, allocator = allocator) }
		atomic_report(checker, file_id, node, reason) or_return
		return false, nil
	}
	address := atomic_address_of(checker, view, scope, file, node) or_return
	if address == 0 { return true, nil }
	target := atomic_unparen(file, syntax.node_payload(file.ast, address, syntax.Unary_Expr).expr)
	target_text := expression_to_string(file, target)

	current := target
	for {
		base: syntax.Node_Index
		#partial switch file.ast.nodes[current].kind {
		case .Selector_Expr:
			base = syntax.node_payload(file.ast, current, syntax.Selector_Expr).expr
		case .Index_Expr:
			index := syntax.node_payload(file.ast, current, syntax.Index_Expr)
			base_info := check_expression(checker, view, scope, index.expr) or_return
			if !atomic_array_like(store, base_info.type) { break }
			base = index.expr
		case:
		}
		if base == 0 { break }
		base_info := check_expression(checker, view, scope, base) or_return
		is_pointer := types.get(store, types.resolve_named(store, base_info.type)).kind == .Pointer
		if atomic_packed_struct(store, base_info.type) {
			reason := fmt.aprintf("'%s' may be misaligned for '%s', as it is within a #packed struct", target_text, builtin_name, allocator = allocator)
			atomic_report(checker, file_id, node, reason) or_return
			return false, nil
		}
		if is_pointer { break }
		current = atomic_unparen(file, base)
	}

	known := atomic_address_alignment(checker, view, scope, file, target) or_return
	if known < size {
		reason := fmt.aprintf(
			"'%s' may be misaligned for '%s' of '%s', as it is only known to be %d byte aligned",
			target_text,
			builtin_name,
			types.type_text(store, element, allocator),
			known,
			allocator = allocator,
		)
		atomic_report(checker, file_id, node, reason) or_return
		return false, nil
	}

	if writes {
		entity, within := atomic_rodata_root(checker, view, scope, file, target) or_return
		if entity != nil {
			reason: string
			if within {
				reason = fmt.aprintf(
					"'%s' is within @(rodata) '%s', which faults when written, as '%s' does",
					target_text,
					entity.name,
					builtin_name,
					allocator = allocator,
				)
			} else {
				reason = fmt.aprintf("'%s' is @(rodata), which faults when written, as '%s' does", target_text, builtin_name, allocator = allocator)
			}
			atomic_report(checker, file_id, node, reason) or_return
			return false, nil
		}
	}
	return true, nil
}

@(private = "file")
atomic_valid_kind :: proc(kind: types.Kind) -> bool {
	#partial switch kind {
	case .Pointer, .Raw_Pointer, .Multi_Pointer, .CString, .CString16, .Procedure, .Bit_Set, .Bool, .Integer, .Float, .Rune:
		return true
	}
	return false
}

@(private = "file")
atomic_unparen :: proc(file: ^File, node: syntax.Node_Index) -> syntax.Node_Index {
	current := node
	for file.ast.nodes[current].kind == .Paren_Expr { current = syntax.node_payload(file.ast, current, syntax.Paren_Expr).expr }
	return current
}

@(private = "file")
atomic_array_like :: proc(store: ^types.Store, id: types.Type_Id) -> bool {
	kind := types.get(store, types.resolve_named(store, id)).kind
	return kind == .Array || kind == .Enumerated_Array || kind == .Fixed_Capacity_Array
}

@(private = "file")
atomic_packed_struct :: proc(store: ^types.Store, id: types.Type_Id) -> bool {
	base := types.get(store, types.resolve_named(store, id))
	if base.kind == .Pointer { base = types.get(store, types.resolve_named(store, base.elem)) }
	return base.kind == .Struct && base.packed
}

// The `&x` an atomic operation's pointer is, through conversions of it; 0 for a pointer from elsewhere.
@(private = "file")
atomic_address_of :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file: ^File,
	node: syntax.Node_Index,
) -> (
	address: syntax.Node_Index,
	err: Resolve_Error,
) {
	current := atomic_unparen(file, node)
	loop: for {
		#partial switch file.ast.nodes[current].kind {
		case .Call_Expr:
			call := syntax.node_payload(file.ast, current, syntax.Call_Expr)
			arguments := syntax.node_list(file.ast, call.args)
			if len(arguments) != 1 { break loop }
			callee := check_expression(checker, view, scope, call.expr) or_return
			if callee.mode != .Type { break loop }
			current = atomic_unparen(file, arguments[0])
		case .Type_Cast:
			current = atomic_unparen(file, syntax.node_payload(file.ast, current, syntax.Type_Cast).expr)
		case .Auto_Cast:
			current = atomic_unparen(file, syntax.node_payload(file.ast, current, syntax.Auto_Cast).expr)
		case:
			break loop
		}
	}
	if file.ast.nodes[current].kind != .Unary_Expr || syntax.node_payload(file.ast, current, syntax.Unary_Expr).op.kind != .And { return 0, nil }
	return current, nil
}

@(private = "file")
type_alignment :: proc(store: ^types.Store, id: types.Type_Id) -> i64 {
	_, align, _ := types.layout(store, id)
	return align
}

// The alignment the checker can prove for the address of `node`, as check_atomic_address_alignment.
@(private = "file")
atomic_address_alignment :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file: ^File,
	node: syntax.Node_Index,
) -> (
	align: i64,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	current := atomic_unparen(file, node)
	info := check_expression(checker, view, scope, current) or_return
	fallback := type_alignment(store, info.type)
	if info.entity != 0 {
		if variable := entity_get(checker.type_checker.resolver.scopes, info.entity); variable.kind == .Variable {
			return max(fallback, variable_custom_align(checker, info.entity) or_return), nil
		}
	}
	#partial switch file.ast.nodes[current].kind {
	case .Selector_Expr:
		selector := syntax.node_payload(file.ast, current, syntax.Selector_Expr)
		base := check_expression(checker, view, scope, selector.expr) or_return
		container := base.type
		is_pointer := false
		if pointer := types.get(store, types.resolve_named(store, container)); pointer.kind == .Pointer {
			container, is_pointer = pointer.elem, true
		}
		record := types.get(store, types.resolve_named(store, container))
		if record.kind != .Struct { return fallback, nil }
		name := expression_text(file, selector.field)
		for field, index in record.fields {
			if field.name != name { continue }
			align = type_alignment(store, container)
			if !is_pointer { align = atomic_address_alignment(checker, view, scope, file, selector.expr) or_return }
			offset, _ := types.field_offset(store, types.resolve_named(store, container), index)
			if offset != 0 { align = min(align, offset & -offset) }
			return align, nil
		}
	case .Index_Expr:
		index := syntax.node_payload(file.ast, current, syntax.Index_Expr)
		base := check_expression(checker, view, scope, index.expr) or_return
		array := types.get(store, types.resolve_named(store, base.type))
		if array.kind != .Array { return fallback, nil }
		align = atomic_address_alignment(checker, view, scope, file, index.expr) or_return
		offset, _, _ := types.layout(store, array.elem)
		position := check_expression(checker, view, scope, index.index) or_return
		if position.mode == .Constant {
			if value, is_integer := constant_pool_get(checker.constants, position.constant).value.(big.Int); is_integer {
				count, _ := big.int_get_i64(&value)
				offset *= count
			}
		}
		if offset != 0 { align = min(align, offset & -offset) }
		return align, nil
	}
	return fallback, nil
}

// The variable an address is within and whether it is @(rodata); `within` is false when the address is the variable itself.
@(private = "file")
atomic_rodata_root :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file: ^File,
	node: syntax.Node_Index,
) -> (
	entity: ^Entity,
	within: bool,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	scopes := checker.type_checker.resolver.scopes
	current := node
	loop: for {
		#partial switch file.ast.nodes[current].kind {
		case .Selector_Expr:
			selector := syntax.node_payload(file.ast, current, syntax.Selector_Expr)
			base := check_expression(checker, view, scope, selector.expr) or_return
			if base.entity != 0 && entity_get(scopes, base.entity).kind == .Import_Name { break loop }
			if types.get(store, types.resolve_named(store, base.type)).kind == .Pointer { break loop }
			current = atomic_unparen(file, selector.expr)
		case .Index_Expr:
			index := syntax.node_payload(file.ast, current, syntax.Index_Expr)
			base := check_expression(checker, view, scope, index.expr) or_return
			if !atomic_array_like(store, base.type) { break loop }
			current = atomic_unparen(file, index.expr)
		case:
			break loop
		}
	}
	if kind := file.ast.nodes[current].kind; kind != .Ident && kind != .Selector_Expr { return nil, false, nil }
	info := check_expression(checker, view, scope, current) or_return
	if info.entity == 0 { return nil, false, nil }
	found := entity_get(scopes, info.entity)
	if found.kind != .Variable || .Rodata not_in found.flags { return nil, false, nil }
	return found, current != node, nil
}

// The `@(align=N)` of a global variable, 0 when it has none.
@(private = "file")
variable_custom_align :: proc(checker: ^Expression_Checker, id: Entity_Id) -> (align: i64, err: Resolve_Error) {
	entity := entity_get(checker.type_checker.resolver.scopes, id)
	declaration, scope := entity.declaration, entity.scope
	if declaration.node == 0 { return 0, nil }
	file := checker.type_checker.files[declaration.file]
	if file.ast.nodes[declaration.node].kind != .Value_Decl { return 0, nil }
	view := expression_file_view(checker, declaration.file) or_return
	for attribute in syntax.node_list(file.ast, syntax.node_payload(file.ast, declaration.node, syntax.Value_Decl).attributes) {
		for element in syntax.node_list(file.ast, syntax.node_payload(file.ast, attribute, syntax.Attribute).elems) {
			if file.ast.nodes[element].kind != .Field_Value { continue }
			field := syntax.node_payload(file.ast, element, syntax.Field_Value)
			if expression_text(file, field.field) != "align" { continue }
			info := check_expression(checker, view, scope, field.value) or_return
			if info.state == .Invalid || info.mode != .Constant { return 0, nil }
			if value, is_integer := constant_pool_get(checker.constants, info.constant).value.(big.Int); is_integer { align, _ = big.int_get_i64(&value) }
			return align, nil
		}
	}
	return 0, nil
}

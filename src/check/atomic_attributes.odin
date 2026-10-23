package check

import "core:fmt"
import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

Atomic_Order :: enum u8 {
	Relaxed,
	Consume,
	Acquire,
	Release,
	Acq_Rel,
	Seq_Cst,
}

Futex_Kind :: enum u8 {
	None,
	Wait,
	Wake,
}

// Validated `@(futex)`, `@(futex_parameter)`, `@(synchronizes)` and `@(synchronizes_shared)` of a procedure; generic instances copy it.
Atomic_Attributes :: struct {
	futex:               Futex_Kind,
	futex_parameter:     int,
	parameter_name:      string,
	synchronizes:        Atomic_Order,
	synchronizes_shared: bool,
}

@(private = "file")
Attribute_Value :: enum u8 {
	Wrong,
	Silent,
	Right,
}

@(private = "package")
atomic_report :: proc(checker: ^Expression_Checker, file_id: File_Id, node: syntax.Node_Index, reason: string) -> Resolve_Error {
	span := checker.type_checker.files[file_id].ast.nodes[node]
	source := Source_Span{file_id, span.start, span.end}
	for existing in checker.diagnostics {
		if existing.kind == .Atomic && existing.source == source && existing.reason == reason { return nil }
	}
	_, err := append(&checker.diagnostics, Expression_Diagnostic{kind = .Atomic, source = source, reason = reason})
	return err
}

// The official attribute handling in checker.cpp (futex, synchronizes, futex_parameter) and check_proc_decl; `signature` is 0 for a generic procedure.
@(private = "package")
check_atomic_attributes :: proc(
	checker: ^Expression_Checker,
	id: Entity_Id,
	name_node, proc_type: syntax.Node_Index,
	signature: types.Type_Id,
) -> Resolve_Error {
	scopes := checker.type_checker.resolver.scopes
	entity := entity_get(scopes, id)
	declaration, scope := entity.declaration, entity.scope
	if declaration.node == 0 { return nil }
	file := checker.type_checker.files[declaration.file]
	if file.ast.nodes[declaration.node].kind != .Value_Decl { return nil }
	decl := syntax.node_payload(file.ast, declaration.node, syntax.Value_Decl)
	view := expression_file_view(checker, declaration.file) or_return
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	order_type := intrinsics_type(checker, "Atomic_Memory_Order") or_return
	futex_type := intrinsics_type(checker, "Futex_Operation") or_return
	attributes: Atomic_Attributes
	parameter_name := ""
	for attribute in syntax.node_list(file.ast, decl.attributes) {
		for element in syntax.node_list(file.ast, syntax.node_payload(file.ast, attribute, syntax.Attribute).elems) {
			name_part, value := element, syntax.Node_Index(0)
			if file.ast.nodes[element].kind == .Field_Value {
				field := syntax.node_payload(file.ast, element, syntax.Field_Value)
				name_part, value = field.field, field.value
			}
			name := expression_text(file, name_part)
			switch name {
			case "futex":
				number, state := attribute_enum_value(checker, view, scope, value, futex_type) or_return
				switch state {
				case .Wrong:
					reason := fmt.aprintf(
						"Expected a constant of type 'intrinsics.Futex_Operation' for '%s', i.e. '.Wait' or '.Wake'",
						name,
						allocator = allocator,
					)
					atomic_report(checker, declaration.file, element, reason) or_return
				case .Right:
					attributes.futex = .Wait if number == 0 else .Wake
				case .Silent:
				}
			case "synchronizes", "synchronizes_shared":
				number, state := attribute_enum_value(checker, view, scope, value, order_type) or_return
				switch state {
				case .Wrong:
					reason := fmt.aprintf(
						"Expected a constant of type 'intrinsics.Atomic_Memory_Order' for '%s', e.g. '.Acquire' or '.Release'",
						name,
						allocator = allocator,
					)
					atomic_report(checker, declaration.file, element, reason) or_return
				case .Right:
					switch {
					case number == 0:
						reason := fmt.aprintf("'%s' cannot be '.Relaxed', which synchronizes nothing", name, allocator = allocator)
						atomic_report(checker, declaration.file, element, reason) or_return
					case attributes.synchronizes != .Relaxed:
						atomic_report(checker, declaration.file, element, "'synchronizes' and 'synchronizes_shared' cannot both be used") or_return
					case:
						attributes.synchronizes = Atomic_Order(number)
						attributes.synchronizes_shared = name == "synchronizes_shared"
					}
				case .Silent:
				}
			case "futex_parameter":
				text, found := attribute_string_value(checker, view, scope, value) or_return
				if found {
					parameter_name = text
				} else {
					reason := fmt.aprintf("Expected the name of a parameter for '%s'", name, allocator = allocator)
					atomic_report(checker, declaration.file, element, reason) or_return
				}
			}
		}
	}
	if attributes.futex == .None && parameter_name != "" {
		atomic_report(checker, declaration.file, name_node, "@(futex_parameter) can only be used with @(futex)") or_return
	}
	attributes.parameter_name = parameter_name
	if attributes.futex != .None {
		names: []string
		pointers: []bool
		if signature != 0 {
			names, pointers = concrete_parameters(checker, signature) or_return
		} else {
			names, pointers = declared_parameters(checker, declaration.file, scope, proc_type) or_return
		}
		attributes.futex_parameter = check_futex_parameter(checker, declaration.file, name_node, parameter_name, names, pointers) or_return
	}
	procedure := &entity_get(scopes, id).data.(Procedure_Data)
	procedure.atomic = attributes
	return nil
}

@(private = "file")
concrete_parameters :: proc(checker: ^Expression_Checker, signature: types.Type_Id) -> (names: []string, pointers: []bool, err: Resolve_Error) {
	store := checker.type_checker.store
	descriptor := types.get(store, signature)
	pointers = make([]bool, len(descriptor.params), mem.dynamic_arena_allocator(&checker.arena)) or_return
	for parameter, index in descriptor.params { pointers[index] = pointer_to_integer(store, parameter) }
	return descriptor.param_names, pointers, nil
}

// A generic declaration has no signature: a parameter qualifies when it is written as a pointer to a polymorphic type or an integer.
@(private = "file")
declared_parameters :: proc(
	checker: ^Expression_Checker,
	file_id: File_Id,
	scope: Scope_Id,
	proc_type: syntax.Node_Index,
) -> (
	names: []string,
	pointers: []bool,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	params := syntax.node_payload(file.ast, proc_type, syntax.Proc_Type).params
	if params == 0 { return nil, nil, nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	name_list := make([dynamic]string, allocator) or_return
	pointer_list := make([dynamic]bool, allocator) or_return
	for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, params, syntax.Field_List).list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		for name in syntax.node_list(file.ast, field.names) {
			text := expression_text(file, name)
			if file.ast.nodes[name].kind == .Poly_Type { text = expression_text(file, syntax.node_payload(file.ast, name, syntax.Poly_Type).type) }
			append(&name_list, text) or_return
			pointer := false
			if field.type != 0 && file.ast.nodes[field.type].kind == .Pointer_Type {
				element := syntax.node_payload(file.ast, field.type, syntax.Pointer_Type).elem
				pointer = declared_pointee_fits(checker, file_id, scope, name_list[:], element) or_return
			}
			append(&pointer_list, pointer) or_return
		}
	}
	return name_list[:], pointer_list[:], nil
}

// A pointee that is polymorphic, or names a polymorphic parameter, fits; any other must be an integer.
@(private = "file")
declared_pointee_fits :: proc(
	checker: ^Expression_Checker,
	file_id: File_Id,
	scope: Scope_Id,
	names: []string,
	element: syntax.Node_Index,
) -> (
	fits: bool,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	if file.ast.nodes[element].kind == .Poly_Type { return true, nil }
	text := expression_text(file, element)
	for name in names {
		if name == text { return true, nil }
	}
	pointee := type_expression(checker.type_checker, file_id, scope, element, true) or_return
	if pointee == types.TYPE_POISON { return true, nil }
	store := checker.type_checker.store
	return types.get(store, types.resolve_named(store, pointee)).kind == .Integer, nil
}

// The index of the parameter `@(futex)` waits on or wakes, as check_proc_decl finds it; reports a missing or unsuitable one.
@(private = "file")
check_futex_parameter :: proc(
	checker: ^Expression_Checker,
	file_id: File_Id,
	name_node: syntax.Node_Index,
	parameter_name: string,
	names: []string,
	pointers: []bool,
) -> (
	parameter: int,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	parameter = -1
	for name, index in names {
		if parameter_name == "" || name == parameter_name {
			parameter = index
			break
		}
	}
	if parameter < 0 && parameter_name != "" {
		reason := fmt.aprintf(
			"@(futex_parameter) names '%s', which is not a parameter of '%s'",
			parameter_name,
			expression_text(file, name_node),
			allocator = mem.dynamic_arena_allocator(&checker.arena),
		)
		atomic_report(checker, file_id, name_node, reason) or_return
	} else if parameter < 0 || !pointers[parameter] {
		reason := "A procedure with @(futex) must take a pointer to an integer as its first parameter, or the one @(futex_parameter) names, which is what it waits on or wakes"
		atomic_report(checker, file_id, name_node, reason) or_return
	}
	return max(parameter, 0), nil
}

@(private = "file")
pointer_to_integer :: proc(store: ^types.Store, id: types.Type_Id) -> bool {
	pointer := types.get(store, types.resolve_named(store, id))
	return pointer.kind == .Pointer && types.get(store, types.resolve_named(store, pointer.elem)).kind == .Integer
}

@(private = "file")
attribute_enum_value :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	value: syntax.Node_Index,
	enum_type: types.Type_Id,
) -> (
	number: i64,
	state: Attribute_Value,
	err: Resolve_Error,
) {
	if value == 0 { return 0, .Wrong, nil }
	if enum_type == 0 { return 0, .Silent, nil }
	info := check_expression(checker, view, scope, value, enum_type, false) or_return
	if info.state == .Invalid { return 0, .Silent, nil }
	if info.mode != .Constant || info.type != enum_type { return 0, .Wrong, nil }
	pool_value := constant_pool_get(checker.constants, info.constant)
	if pool_value == nil { return 0, .Wrong, nil }
	integer, is_integer := pool_value.value.(big.Int)
	if !is_integer { return 0, .Wrong, nil }
	number, _ = big.int_get_i64(&integer)
	return number, .Right, nil
}

@(private = "file")
attribute_string_value :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	value: syntax.Node_Index,
) -> (
	text: string,
	found: bool,
	err: Resolve_Error,
) {
	if value == 0 { return "", false, nil }
	info := check_expression(checker, view, scope, value) or_return
	if info.state == .Invalid || info.mode != .Constant { return "", false, nil }
	pool_value := constant_pool_get(checker.constants, info.constant)
	if pool_value == nil { return "", false, nil }
	text, found = pool_value.value.(string)
	return text, found && text != "", nil
}

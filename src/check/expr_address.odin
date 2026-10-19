package check

import "core:fmt"
import "core:mem"
import "oc:syntax"
import "oc:types"

// Dereferencing a pointer names its pointee; lowering loads or stores through the pointer value.
@(private = "package")
expression_deref :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	pointer := check_expression(checker, view, scope, syntax.node_payload(file.ast, node, syntax.Deref_Expr).expr) or_return
	if pointer.state == .Invalid { return expression_poison(scope), nil }
	if pointer.type == types.TYPE_NONE { return expression_missing_operand_type(checker, view, scope, node, pointer.mode) }
	descriptor := types.get(checker.type_checker.store, pointer.type)
	if descriptor.kind != .Pointer { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	return Expression_Info{type = descriptor.elem, mode = .Variable, scope = scope, state = .Checked}, nil
}

// Only addressable operands have a pointer. The address-of row is the marker lowering scans for.
@(private = "package")
expression_address :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	operand := syntax.node_payload(file.ast, node, syntax.Unary_Expr).expr
	target := check_expression(checker, view, scope, operand) or_return
	if target.state == .Invalid { return expression_poison(scope), nil }
	if target.plan != 0 {
		if swizzle, is_swizzle := checker.plans[target.plan].(Swizzle_Plan); is_swizzle && swizzle.count > 1 {
			reason := fmt.aprintf(
				"Cannot take the pointer address of '%s' which is a swizzle intermediate array value",
				expression_text(file, operand),
				allocator = mem.dynamic_arena_allocator(&checker.arena),
			)
			return expression_failure(checker, view, scope, node, .Invalid_Operand, reason)
		}
		if place, is_place := checker.plans[target.plan].(Place_Plan); is_place && place.bit_size != 0 {
			return expression_unsupported(checker, view, scope, node, "Address_Bit_Field")
		}
	}
	is_composite_literal := file.ast.nodes[type_unparen(file, operand)].kind == .Comp_Lit
	// Variables, map elements, composite literals and type assertions are addressable (check_expr.cpp:3105-3135, check_is_not_addressable).
	is_addressable := target.mode == .Variable || target.mode == .Map_Index || is_composite_literal || expression_assertion_addressable(checker, target)
	if !is_addressable { return expression_unsupported(checker, view, scope, node, "Address_Mode") }
	pointer := types.intern(checker.type_checker.store, types.Type{kind = .Pointer, elem = target.type})
	if target.mode == .Map_Index || target.mode == .Optional_Ok {
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Address_Plan{})) or_return
		return Expression_Info{type = pointer, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	return Expression_Info{type = pointer, mode = .Value, scope = scope, state = .Checked}, nil
}

// `&m[k]` and `&x.(T)` have the optional-ok form (check_expr.cpp:3322-3326): a pointer and a bool in a two-target context.
Address_Plan :: struct {
	comma_ok: bool,
}

// A type assertion on a pointer or `any`, or on a union variable, names an addressable value (check_expr.cpp:3111-3131).
@(private = "file")
expression_assertion_addressable :: proc(checker: ^Expression_Checker, target: Expression_Info) -> bool {
	if target.mode != .Optional_Ok || target.plan == 0 { return false }
	assertion, is_assertion := checker.plans[target.plan].(Type_Assertion_Plan)
	if !is_assertion { return false }
	store := checker.type_checker.store
	source_kind := types.get(store, types.resolve_named(store, assertion.source_type)).kind
	if source_kind == .Pointer || source_kind == .Any { return true }
	if source_kind != .Union { return false }
	source, is_expression := assertion.source.(Expression_Ref)
	if !is_expression { return false }
	source_view := checker.views[source.view]
	return source_view.nodes.modes[int(source.node - source_view.first_node)] == .Variable
}

// A selector on an import name reads a member of the imported package scope; otherwise it names a struct field.
@(private = "package")
expression_selector :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	hint: types.Type_Id = 0,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	selector := syntax.node_payload(file.ast, node, syntax.Selector_Expr)
	scopes := checker.type_checker.resolver.scopes
	if file.ast.nodes[selector.expr].kind == .Ident {
		name, _ := scope_lookup(scopes, scope, expression_text(file, selector.expr))
		if name != 0 && entity_get(scopes, name).kind == .Import_Name {
			return expression_import_member(checker, view, file_id, scope, node, name)
		}
		if name != 0 && entity_get(scopes, name).kind == .Type_Name {
			if _, resolve_error := resolve_entity(checker.type_checker.resolver, name); resolve_error != nil { return {}, resolve_error }
			enum_type := entity_get(scopes, name).type
			if enum_type == types.TYPE_NONE { return expression_missing_operand_type(checker, view, scope, selector.expr, .Type) }
			if types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, enum_type)).kind == .Enum {
				return expression_enum_member(checker, view, scope, node, enum_type, expression_text(file, selector.field))
			}
		}
	}
	return expression_field(checker, view, file_id, scope, node, hint)
}

@(private = "file")
expression_import_member :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	import_name: Entity_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	selector := syntax.node_payload(file.ast, node, syntax.Selector_Expr)
	scopes := checker.type_checker.resolver.scopes
	package_id := entity_get(scopes, import_name).data.(Import_Data).package_id
	if int(package_id) >= len(checker.packages) { return expression_unsupported(checker, view, scope, node, "Selector_Package") }
	member := scope_lookup_current(scopes, checker.packages[package_id].scope, expression_text(file, selector.field))
	if member == 0 { return expression_failure(checker, view, scope, node, .Undeclared_Name) }
	return expression_entity_info(checker, file_id, scope, node, member)
}

// Lowering computes the field address from the base value: an aggregate's address or a pointer's value.
@(private = "file")
expression_field :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	hint: types.Type_Id = 0,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	selector := syntax.node_payload(file.ast, node, syntax.Selector_Expr)
	base := check_expression(checker, view, scope, selector.expr) or_return
	if base.state == .Invalid { return expression_poison(scope), nil }
	if base.type == types.TYPE_NONE { return expression_missing_operand_type(checker, view, scope, selector.expr, base.mode) }
	store := checker.type_checker.store
	owner := types.resolve_named(store, base.type)
	indirect := types.get(store, owner).kind == .Pointer
	if indirect { owner = types.resolve_named(store, types.get(store, owner).elem) }
	descriptor := types.get(store, owner)
	if base.mode == .Type && descriptor.kind == .Enum {
		return expression_enum_member(checker, view, scope, node, base.type, expression_text(file, selector.field))
	}
	if descriptor.kind == .Array {
		return expression_array_selector(checker, view, file_id, scope, node, base, descriptor^, indirect, hint)
	}
	is_container := descriptor.kind == .Dynamic_Array || descriptor.kind == .Map
	if (descriptor.kind != .Struct && descriptor.kind != .Bit_Field && descriptor.kind != .Any && !is_container) ||
	   (!indirect && base.mode != .Variable && base.mode != .Value && base.mode != .Immutable_Value && base.mode != .Context && base.mode != .Constant) {
		return expression_unsupported(checker, view, scope, node, "Selector_Base")
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	path := make([dynamic]Member_Step, 0, allocator) or_return
	field_type: types.Type_Id
	found := false
	if is_container {
		if expression_text(file, selector.field) == "allocator" {
			field_type = runtime_type_named(checker, "Allocator")
			if field_type == types.TYPE_NONE { return expression_unsupported(checker, view, scope, node, "Selector_Allocator_Type") }
			index: u32 = 3 if descriptor.kind == .Dynamic_Array else 2
			append(&path, Member_Step{type = owner, field_index = index, indirect = indirect}) or_return
			found = true
		}
	} else if descriptor.kind == .Any {
		field := expression_text(file, selector.field)
		index := -1
		if field == "data" {
			index, field_type = 0, types.intern(store, types.Type{kind = .Raw_Pointer})
		} else if field == "id" {
			index, field_type = 1, types.intern(store, types.Type{kind = .Type_Id})
		}
		if index >= 0 {
			append(&path, Member_Step{type = owner, field_index = u32(index), indirect = indirect}) or_return
			found = true
		}
	} else {
		field_type, found = field_path(checker, owner, indirect, expression_text(file, selector.field), &path)
	}
	if !found { return expression_failure(checker, view, scope, selector.field, .Undeclared_Name) }
	if base.mode == .Constant && !indirect {
		constant := base.constant
		for step in path {
			value := constant_pool_get(checker.constants, constant)
			if value == nil { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
			aggregate, is_aggregate := value.value.(Aggregate_Value)
			if !is_aggregate || int(step.field_index) >= len(aggregate.elements) {
				return expression_failure(checker, view, scope, node, .Invalid_Operand)
			}
			constant = aggregate.elements[step.field_index]
		}
		return Expression_Info{type = field_type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
	}
	plan := Plan_Id(len(checker.plans))
	place := Place_Plan {
		root = Operand(Expression_Ref{view, selector.expr}),
		path = path[:],
	}
	if descriptor.kind == .Bit_Field { place.bit_offset, place.bit_size = types.bit_field_slot(store, owner, int(path[0].field_index)) }
	append(&checker.plans, Plan(place)) or_return
	mode := base.mode
	if indirect || base.mode == .Context { mode = .Variable }
	return Expression_Info{type = field_type, mode = mode, plan = plan, scope = scope, state = .Checked}, nil
}

// Finds a field by name in a struct, then in its by-value `using` fields, depth first. The path lists each member step from owner.
@(private = "package")
field_path :: proc(
	checker: ^Expression_Checker,
	owner: types.Type_Id,
	indirect: bool,
	name: string,
	path: ^[dynamic]Member_Step,
) -> (
	field_type: types.Type_Id,
	found: bool,
) {
	store := checker.type_checker.store
	descriptor := types.get(store, owner)
	if index := struct_field_index(descriptor.fields, name); index >= 0 {
		append(path, Member_Step{type = owner, field_index = u32(index), indirect = indirect})
		return descriptor.fields[index].type, true
	}
	flags := checker.type_checker.field_flags[owner]
	for field, index in descriptor.fields {
		if index >= len(flags) || .Using not_in flags[index] { continue }
		embedded := types.resolve_named(store, field.type)
		if types.get(store, embedded).kind != .Struct { continue }
		mark := len(path)
		append(path, Member_Step{type = owner, field_index = u32(index), indirect = indirect})
		if embedded_type, ok := field_path(checker, embedded, false, name, path); ok { return embedded_type, true }
		resize(path, mark)
	}
	return 0, false
}

@(private = "package")
struct_field_index :: proc(fields: []types.Type_Field, name: string) -> int {
	for field, index in fields {
		if field.name == name { return index }
	}
	return -1
}

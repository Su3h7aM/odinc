package check

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
	if target.mode != .Variable { return expression_unsupported(checker, view, scope, node, "Address_Mode") }
	if target.plan != 0 {
		if place, is_place := checker.plans[target.plan].(Place_Plan); is_place && place.bit_size != 0 {
			return expression_unsupported(checker, view, scope, node, "Address_Bit_Field")
		}
	}
	pointer := types.intern(checker.type_checker.store, types.Type{kind = .Pointer, elem = target.type})
	return Expression_Info{type = pointer, mode = .Value, scope = scope, state = .Checked}, nil
}

// A selector on an import name reads a member of the imported package scope; otherwise it names a struct field.
@(private = "package")
expression_selector :: proc(
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
			if types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, enum_type)).kind == .Enum {
				return expression_enum_member(checker, view, scope, node, enum_type, expression_text(file, selector.field))
			}
		}
	}
	return expression_field(checker, view, file_id, scope, node)
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
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	selector := syntax.node_payload(file.ast, node, syntax.Selector_Expr)
	base := check_expression(checker, view, scope, selector.expr) or_return
	if base.state == .Invalid { return expression_poison(scope), nil }
	store := checker.type_checker.store
	owner := types.resolve_named(store, base.type)
	indirect := types.get(store, owner).kind == .Pointer
	if indirect { owner = types.resolve_named(store, types.get(store, owner).elem) }
	descriptor := types.get(store, owner)
	if (descriptor.kind != .Struct && descriptor.kind != .Bit_Field && descriptor.kind != .Any) ||
	   (!indirect && base.mode != .Variable && base.mode != .Value && base.mode != .Immutable_Value && base.mode != .Context) {
		return expression_unsupported(checker, view, scope, node, "Selector_Base")
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	path := make([dynamic]Member_Step, 0, allocator) or_return
	field_type: types.Type_Id
	found := false
	if descriptor.kind == .Any {
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

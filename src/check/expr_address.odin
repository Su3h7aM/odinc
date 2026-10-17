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
	if target.mode != .Variable { return expression_failure(checker, view, scope, node, .Unsupported) }
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
	if int(package_id) >= len(checker.packages) { return expression_failure(checker, view, scope, node, .Unsupported) }
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
	if descriptor.kind != .Struct || (!indirect && base.mode != .Variable && base.mode != .Value && base.mode != .Immutable_Value) {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	fields := descriptor.fields
	index := struct_field_index(fields, expression_text(file, selector.field))
	if index < 0 { return expression_failure(checker, view, scope, selector.field, .Undeclared_Name) }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	path := make([]Member_Step, 1, allocator) or_return
	path[0] = Member_Step {
		type        = owner,
		field_index = u32(index),
		indirect    = indirect,
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Place_Plan{root = Operand(Expression_Ref{view, selector.expr}), path = path})) or_return
	mode := base.mode
	if indirect { mode = .Variable }
	return Expression_Info{type = fields[index].type, mode = mode, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "package")
struct_field_index :: proc(fields: []types.Type_Field, name: string) -> int {
	for field, index in fields {
		if field.name == name { return index }
	}
	return -1
}

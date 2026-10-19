package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_c_varargs :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	kind := checker.builtin_kinds[builtin]
	count := 2 if kind != .C_Va_End else 1
	if ellipsis || len(arguments) != count { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	resolver := checker.type_checker.resolver
	list_type: types.Type_Id
	for intrinsics_package in checker.packages {
		if intrinsics_package.kind != .Intrinsics { continue }
		entity := scope_lookup_current(resolver.scopes, intrinsics_package.scope, "c_va_list")
		if entity == 0 { continue }
		state := resolve_entity(resolver, entity) or_return
		if state == .Resolved { list_type = entity_get(resolver.scopes, entity).type }
		break
	}
	if list_type == 0 { return expression_unsupported(checker, view, scope, node, "C_Va_List_Type") }
	store := checker.type_checker.store
	pointer_type := types.intern(store, types.Type{kind = .Pointer, elem = list_type})
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, count, allocator) or_return
	result: types.Type_Id
	for argument, index in arguments {
		value := check_expression(checker, view, scope, argument) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		if index == 1 && kind == .C_Va_Arg {
			if value.mode != .Type { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
			result = value.type
		} else if index == 1 && kind == .C_Va_Start {
			if value.entity == 0 || .C_Variadic not_in entity_get(resolver.scopes, value.entity).flags {
				return expression_failure(checker, view, scope, argument, .Invalid_Operand)
			}
		} else if value.type != pointer_type || value.mode == .Type {
			return expression_failure(checker, view, scope, argument, .Invalid_Operand)
		}
		operands[index] = Operand(Expression_Ref{view, argument})
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	mode := Addressing_Mode.No_Value
	if kind == .C_Va_Arg { mode = .Value }
	return Expression_Info{type = result, mode = mode, plan = plan, scope = scope, state = .Checked}, nil
}

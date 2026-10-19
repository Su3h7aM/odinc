package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
is_procedure_value :: proc(checker: ^Expression_Checker, type: types.Type_Id) -> bool {
	if type == 0 { return false }
	store := checker.type_checker.store
	return types.get(store, types.resolve_named(store, type)).kind == .Procedure
}

// A call through a procedure value has no entity. Its arguments map to the parameters of the
// value's procedure type by position, each with the parameter's type.
@(private = "package")
expression_indirect_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	callee_node: syntax.Node_Index,
	callee: Expression_Info,
	arguments: []syntax.Node_Index,
	spread: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if callee.type == types.TYPE_NONE { return expression_missing_operand_type(checker, view, scope, callee_node, callee.mode) }
	descriptor := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, callee.type))
	if spread { return expression_unsupported(checker, view, scope, node, "Indirect_Call_Spread") }
	if descriptor.variadic { return expression_unsupported(checker, view, scope, node, "Indirect_Call_Variadic") }
	if len(arguments) != len(descriptor.params) {
		return expression_unsupported(checker, view, scope, node, "Indirect_Call_Arguments")
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	call_arguments := make([]Call_Argument, len(arguments), allocator) or_return
	for argument, index in arguments {
		value := expression_argument(checker, view, scope, argument, descriptor.params[index], false) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		conversion := expression_conversion_plan(checker, value.plan)
		if conversion != 0 {
			retained := checker.plans[conversion].(Conversion_Plan)
			retained.source = Operand(Expression_Ref{view, argument})
			conversion = Plan_Id(len(checker.plans))
			append(&checker.plans, Plan(retained)) or_return
		}
		call_arguments[index] = Call_Argument {
			value            = Operand(Expression_Ref{view, argument}),
			conversion       = conversion,
			evaluation_order = u32(index),
		}
	}
	results := make([]types.Type_Id, len(descriptor.results), allocator) or_return
	copy(results, descriptor.results)
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Call_Plan{callee = Operand(Expression_Ref{view, callee_node}), arguments = call_arguments, results = results})) or_return
	info = Expression_Info {
		scope = scope,
		state = .Checked,
		plan  = plan,
		mode  = .No_Value,
	}
	if len(results) == 1 { info.type, info.mode = results[0], .Value }
	return info, nil
}

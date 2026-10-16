package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	callee: Expression_Info,
	arguments: []syntax.Node_Index,
	spread: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	scopes := checker.type_checker.resolver.scopes
	procedure := entity_get(scopes, callee.entity).data.(Procedure_Data)
	descriptor := types.get(checker.type_checker.store, procedure.signature)
	if spread ||
	   descriptor.variadic ||
	   len(descriptor.results) > 1 ||
	   len(arguments) != len(procedure.parameters) ||
	   len(descriptor.params) != len(arguments) {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	call_arguments := make([]Call_Argument, len(arguments), allocator) or_return
	for argument, index in arguments {
		value := check_expression(checker, view, scope, argument, descriptor.params[index]) or_return
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
			parameter        = procedure.parameters[index],
			conversion       = conversion,
			evaluation_order = u32(index),
		}
	}
	results := make([]types.Type_Id, len(descriptor.results), allocator) or_return
	copy(results, descriptor.results)
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Call_Plan{callee = Operand(callee.entity), entity = callee.entity, arguments = call_arguments, results = results})) or_return
	info = Expression_Info {
		scope = scope,
		state = .Checked,
		plan  = plan,
		mode  = .No_Value,
	}
	if len(results) == 1 { info.type, info.mode = results[0], .Value }
	return info, nil
}

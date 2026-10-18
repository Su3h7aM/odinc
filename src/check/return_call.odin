package check

import "core:mem"
import "oc:syntax"

// `return f()` returns each result of a call that yields as many values as the procedure. Each result converts to
// its result type as an assignment does. handled is false when the value is not such a call.
@(private = "package")
expression_returned_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	source: syntax.Node_Index,
) -> (
	handled: bool,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	if file.ast.nodes[source].kind != .Call_Expr { return false, nil }
	info := check_expression(checker, view, scope, source) or_return
	if info.state == .Invalid { return true, nil }
	if info.plan == 0 { return false, nil }
	call, is_call := checker.plans[info.plan].(Call_Plan)
	if !is_call || len(call.results) != len(checker.results) { return false, nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, len(call.results), allocator) or_return
	conversions := make([]Plan_Id, len(call.results), allocator) or_return
	for result, index in call.results {
		operand := Operand(Projection{Expression_Ref{view, source}, u32(index)})
		converted := expression_conversion(
			checker,
			view,
			scope,
			source,
			operand,
			Expression_Info{type = result, mode = .Value, scope = scope, state = .Checked},
			checker.results[index],
			.Assignment,
		) or_return
		if converted.state == .Invalid { return true, nil }
		operands[index] = operand
		conversions[index] = converted.plan
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Exit_Plan{kind = .Return, values = operands, conversions = conversions})) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
	return true, nil
}

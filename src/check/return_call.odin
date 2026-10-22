package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// Each projected result converts to its declared return type as an assignment does.
@(private = "package")
expression_returned_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	source_node: syntax.Node_Index,
) -> (
	handled: bool,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	source := type_unparen(file, source_node)
	hint: types.Type_Id
	if file.ast.nodes[source].kind == .Type_Assertion {
		assertion := syntax.node_payload(file.ast, source, syntax.Type_Assertion)
		if assertion.type == 0 ||
		   file.ast.nodes[assertion.type].kind == .Unary_Expr && syntax.node_payload(file.ast, assertion.type, syntax.Unary_Expr).op.kind == .Question {
			hint = checker.results[0]
		}
	}
	info := check_expression(checker, view, scope, source, hint) or_return
	if info.state == .Invalid { return true, nil }
	pair: [2]types.Type_Id
	results := expression_result_types(checker, info, len(checker.results) == 2, &pair)
	if len(results) != len(checker.results) { return false, nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, len(results), allocator) or_return
	conversions := make([]Plan_Id, len(results), allocator) or_return
	for result, index in results {
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
		retained := checker.plans[converted.plan].(Conversion_Plan)
		retained.source_type = result
		checker.plans[converted.plan] = Plan(retained)
		operands[index] = operand
		conversions[index] = converted.plan
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Exit_Plan{kind = .Return, values = operands, conversions = conversions})) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
	return true, nil
}

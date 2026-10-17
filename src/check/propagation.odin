package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_or_else :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	ast := checker.type_checker.files[file_id].ast
	expression := syntax.node_payload(ast, node, syntax.Or_Else_Expr)
	operand := check_expression(checker, view, scope, expression.x) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	if operand.plan == 0 { return expression_failure(checker, view, scope, node, .Unsupported) }
	call, is_call := checker.plans[operand.plan].(Call_Plan)
	if !is_call || len(call.results) != 2 {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	store := checker.type_checker.store
	payload_type := call.results[0]
	status_type := types.get(store, types.resolve_named(store, call.results[1]))
	if types.get(store, types.resolve_named(store, payload_type)).kind == .Union {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	test: Optional_Test
	#partial switch status_type.kind {
	case .Bool, .Untyped_Bool:
		test = .Boolean_True
	case .Pointer:
		test = .Nil
	case:
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	value := check_expression(checker, view, scope, expression.y, payload_type) or_return
	if value.state == .Invalid { return expression_poison(scope), nil }
	if value.mode == .No_Value || value.mode == .Type {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	values, alloc_error := make([]Operand, 1, mem.dynamic_arena_allocator(&checker.arena))
	if alloc_error != nil { return {}, alloc_error }
	values[0] = Operand(Projection{Expression_Ref{view, expression.x}, 0})
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Propagation_Plan{operand = Expression_Ref{view, expression.x}, test = test, values = values})) or_return
	return Expression_Info{type = payload_type, mode = .Value, scope = scope, plan = plan, state = .Checked}, nil
}

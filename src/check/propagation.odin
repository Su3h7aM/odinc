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
	if operand.plan == 0 { return expression_unsupported(checker, view, scope, node, "Or_Else_Plan") }
	call, is_call := checker.plans[operand.plan].(Call_Plan)
	if !is_call || len(call.results) != 2 {
		return expression_unsupported(checker, view, scope, node, "Or_Else_Results")
	}
	store := checker.type_checker.store
	payload_type := call.results[0]
	status_type := types.get(store, types.resolve_named(store, call.results[1]))
	if types.get(store, types.resolve_named(store, payload_type)).kind == .Union {
		return expression_unsupported(checker, view, scope, node, "Or_Else_Union")
	}
	test: Optional_Test
	#partial switch status_type.kind {
	case .Bool, .Untyped_Bool:
		test = .Boolean_True
	case .Pointer:
		test = .Nil
	case:
		return expression_unsupported(checker, view, scope, node, "Or_Else_Status")
	}
	value := check_expression(checker, view, scope, expression.y, payload_type) or_return
	if value.state == .Invalid { return expression_poison(scope), nil }
	if value.mode == .No_Value || value.mode == .Type {
		return expression_unsupported(checker, view, scope, node, "Or_Else_Fallback")
	}
	values, alloc_error := make([]Operand, 1, mem.dynamic_arena_allocator(&checker.arena))
	if alloc_error != nil { return {}, alloc_error }
	values[0] = Operand(Projection{Expression_Ref{view, expression.x}, 0})
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Propagation_Plan{operand = Expression_Ref{view, expression.x}, test = test, values = values})) or_return
	return Expression_Info{type = payload_type, mode = .Value, scope = scope, plan = plan, state = .Checked}, nil
}

@(private = "package")
expression_or_branch :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if checker.defer_depth != 0 { return expression_unsupported(checker, view, scope, node, "Or_Branch_In_Defer") }
	ast := checker.type_checker.files[file_id].ast
	expression := syntax.node_payload(ast, node, syntax.Or_Branch_Expr)
	if expression.token.kind != .Or_Break && expression.token.kind != .Or_Continue {
		return expression_unsupported(checker, view, scope, node, "Or_Branch_Token")
	}
	is_continue := expression.token.kind == .Or_Continue
	operand := check_expression(checker, view, scope, expression.expr) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	if operand.plan == 0 { return expression_unsupported(checker, view, scope, node, "Or_Branch_Plan") }
	call, is_call := checker.plans[operand.plan].(Call_Plan)
	if !is_call || (len(call.results) != 1 && len(call.results) != 2) {
		return expression_unsupported(checker, view, scope, node, "Or_Branch_Results")
	}
	store := checker.type_checker.store
	status_index := len(call.results) - 1
	status := call.results[status_index]
	status_type := types.get(store, types.resolve_named(store, status))
	test: Optional_Test
	#partial switch status_type.kind {
	case .Bool:
		test = .Boolean_True
	case .Pointer:
		test = .Nil
	case:
		return expression_unsupported(checker, view, scope, node, "Or_Branch_Status")
	}
	for result in call.results {
		if types.get(store, types.resolve_named(store, result)).kind == .Union {
			return expression_unsupported(checker, view, scope, node, "Or_Branch_Union")
		}
	}
	target: Node_Ref
	label := expression_text(checker.type_checker.files[file_id], expression.label)
	for index := len(checker.control) - 1; index >= 0; index -= 1 {
		frame := checker.control[index]
		if label != "" && frame.label != label { continue }
		if label == "" && !frame.is_loop && (is_continue || !frame.is_switch) { continue }
		if is_continue && !frame.is_loop { break }
		target = Node_Ref{file_id, frame.node}
		break
	}
	if target.node == 0 { return expression_unsupported(checker, view, scope, node, "Or_Branch_Target") }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	values: [dynamic]Operand
	if status_index != 0 {
		values = make([dynamic]Operand, allocator) or_return
		append(&values, Operand(Projection{Expression_Ref{view, expression.expr}, 0})) or_return
	}
	failure := Plan_Id(len(checker.plans))
	exit_kind := Exit_Kind.Break
	if is_continue { exit_kind = .Continue }
	append(&checker.plans, Plan(Exit_Plan{kind = exit_kind, target = target})) or_return
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(Propagation_Plan{operand = Expression_Ref{view, expression.expr}, test = test, values = values[:], failure = failure}),
	) or_return
	info = Expression_Info {
		scope = scope,
		plan  = plan,
		mode  = .No_Value,
		state = .Checked,
	}
	if status_index != 0 { info.type, info.mode = call.results[0], .Value }
	return info, nil
}

@(private = "package")
expression_or_return :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if checker.defer_depth != 0 { return expression_unsupported(checker, view, scope, node, "Or_Return_In_Defer") }
	ast := checker.type_checker.files[file_id].ast
	expression := syntax.node_payload(ast, node, syntax.Or_Return_Expr)
	operand := check_expression(checker, view, scope, expression.expr) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	if operand.plan == 0 { return expression_unsupported(checker, view, scope, node, "Or_Return_Plan") }
	call, is_call := checker.plans[operand.plan].(Call_Plan)
	if !is_call || (len(call.results) != 1 && len(call.results) != 2) {
		return expression_unsupported(checker, view, scope, node, "Or_Return_Results")
	}
	store := checker.type_checker.store
	status_index := len(call.results) - 1
	status := call.results[status_index]
	status_type := types.get(store, types.resolve_named(store, status))
	test: Optional_Test
	#partial switch status_type.kind {
	case .Bool:
		test = .Boolean_True
	case .Pointer:
		test = .Nil
	case:
		return expression_unsupported(checker, view, scope, node, "Or_Return_Status")
	}
	for result in call.results {
		if types.get(store, types.resolve_named(store, result)).kind == .Union {
			return expression_unsupported(checker, view, scope, node, "Or_Return_Union")
		}
	}
	returnable := len(checker.results) == 1 && expression_propagation_result_matches(checker, status, checker.results[0])
	if len(checker.results) > 1 &&
	   len(checker.named_results) == len(checker.results) &&
	   expression_propagation_result_matches(checker, status, checker.results[len(checker.results) - 1]) {
		returnable = true
		for result in checker.named_results {
			if result == 0 { returnable = false; break }
		}
	}
	if !returnable { return expression_unsupported(checker, view, scope, node, "Or_Return_Result") }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	failure_values := make([]Operand, 1, allocator) or_return
	failure_values[0] = Operand(Projection{Expression_Ref{view, expression.expr}, u32(status_index)})
	failure := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Exit_Plan{kind = .Return, values = failure_values})) or_return
	values := make([]Operand, status_index, allocator) or_return
	for index in 0 ..< status_index {
		values[index] = Operand(Projection{Expression_Ref{view, expression.expr}, u32(index)})
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Propagation_Plan{operand = Expression_Ref{view, expression.expr}, test = test, values = values, failure = failure})) or_return
	info = Expression_Info {
		scope = scope,
		state = .Checked,
		plan  = plan,
		mode  = .No_Value,
	}
	if len(values) == 1 { info.type, info.mode = call.results[0], .Value }
	return info, nil
}

@(private = "package")
expression_propagation_result_matches :: proc(checker: ^Expression_Checker, status, result: types.Type_Id) -> bool {
	store := checker.type_checker.store
	if status == result { return true }
	status_type := types.get(store, types.resolve_named(store, status))
	result_type := types.get(store, types.resolve_named(store, result))
	return status_type.kind == .Bool && result_type.kind == .Bool
}

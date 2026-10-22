package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "file")
propagation_results :: proc(checker: ^Expression_Checker, plan_id: Plan_Id, value_type: types.Type_Id, pair: ^[2]types.Type_Id) -> []types.Type_Id {
	if plan_id == 0 { return nil }
	#partial switch plan in checker.plans[plan_id] {
	case Call_Plan:
		return plan.results
	case Type_Assertion_Plan:
		assertion := plan
		assertion.comma_ok = true
		checker.plans[plan_id] = Plan(assertion)
		pair^ = {assertion.target_type, checker.boolean}
		return pair[:]
	case Map_Index_Plan:
		indexed := plan
		indexed.comma_ok = true
		checker.plans[plan_id] = Plan(indexed)
		pair^ = {value_type, checker.boolean}
		return pair[:]
	}
	return nil
}

// The result types of a multi-result call argument: a call's results, or the payloads of a multi-value `or_return`.
@(private = "package")
expression_tuple_results :: proc(checker: ^Expression_Checker, file: ^File, node: syntax.Node_Index, info: Expression_Info) -> []types.Type_Id {
	if info.state != .Checked || info.mode != .No_Value || info.plan == 0 || int(info.plan) >= len(checker.plans) { return nil }
	#partial switch plan in checker.plans[info.plan] {
	case Call_Plan:
		if len(plan.results) >= 2 { return plan.results }
	case Propagation_Plan:
		if file.ast.nodes[node].kind == .Or_Return_Expr && len(plan.results) >= 2 { return plan.results }
	}
	return nil
}

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
	operand_hint: types.Type_Id
	if ast.nodes[type_unparen(checker.type_checker.files[file_id], expression.x)].kind == .Type_Assertion { operand_hint = hint }
	operand := check_expression(checker, view, scope, expression.x, operand_hint) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	if operand.plan == 0 { return expression_unsupported(checker, view, scope, node, "Or_Else_Plan") }
	pair: [2]types.Type_Id
	results := propagation_results(checker, operand.plan, operand.type, &pair)
	if len(results) != 2 {
		return expression_unsupported(checker, view, scope, node, "Or_Else_Results")
	}
	store := checker.type_checker.store
	payload_type := results[0]
	status_type := types.get(store, types.resolve_named(store, results[1]))
	test: Optional_Test
	if status_type.kind == .Bool || status_type.kind == .Untyped_Bool {
		test = .Boolean_True
	} else if conversion_nilable(status_type^) {
		test = .Nil
	} else {
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
	append(
		&checker.plans,
		Plan(
			Propagation_Plan {
				operand = Expression_Ref{view, expression.x},
				test = test,
				values = values,
				fallback_conversion = expression_conversion_plan(checker, value.plan),
			},
		),
	) or_return
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
	store := checker.type_checker.store
	if operand.type != 0 && types.get(store, operand.type).kind == .Untyped_Bool {
		operand = check_expression(checker, view, scope, expression.expr, checker.boolean) or_return
		if operand.state == .Invalid { return expression_poison(scope), nil }
	}
	pair: [2]types.Type_Id
	results := propagation_results(checker, operand.plan, operand.type, &pair)
	if len(results) == 0 {
		if operand.mode != .Value && operand.mode != .Variable && operand.mode != .Constant && operand.mode != .Immutable_Value {
			return expression_unsupported(checker, view, scope, node, "Or_Branch_Results")
		}
		pair[0] = operand.type
		results = pair[:1]
	}
	status_index := len(results) - 1
	status := results[status_index]
	status_type := types.get(store, types.resolve_named(store, status))
	test: Optional_Test
	if status_type.kind == .Bool {
		test = .Boolean_True
	} else if conversion_nilable(status_type^) {
		test = .Nil
	} else {
		return expression_unsupported(checker, view, scope, node, "Or_Branch_Status")
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
	branch_results: []types.Type_Id
	if status_index != 0 {
		values = make([dynamic]Operand, allocator) or_return
		branch_results = make([]types.Type_Id, status_index, allocator) or_return
		copy(branch_results, results[:status_index])
		for index in 0 ..< status_index {
			append(&values, Operand(Projection{Expression_Ref{view, expression.expr}, u32(index)})) or_return
		}
	}
	failure := Plan_Id(len(checker.plans))
	exit_kind := Exit_Kind.Break
	if is_continue { exit_kind = .Continue }
	append(&checker.plans, Plan(Exit_Plan{kind = exit_kind, target = target})) or_return
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(Propagation_Plan{operand = Expression_Ref{view, expression.expr}, test = test, values = values[:], failure = failure, results = branch_results}),
	) or_return
	info = Expression_Info {
		scope = scope,
		plan  = plan,
		mode  = .No_Value,
		state = .Checked,
	}
	if status_index != 0 { info.type, info.mode = results[0], .Value }
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
	store := checker.type_checker.store
	// Official check_or_return_expr: the status assigns to the procedure's last result. More than one
	// result requires every result to be named (check_expr.cpp:11204).
	status_index: int
	status: types.Type_Id
	test: Optional_Test
	status_type: ^types.Type
	results: []types.Type_Id
	if operand.plan != 0 {
		pair: [2]types.Type_Id
		results = propagation_results(checker, operand.plan, operand.type, &pair)
	}
	if len(results) == 0 {
		// A stored value: the operand itself is the status, and the expression has no value.
		// Official check_or_return_split_types promotes an operand without a tuple to optional-ok
		// (check_builtin.cpp:144-160).
		status = operand.type
		if operand.mode == .No_Value || operand.mode == .Type || operand.mode == .Builtin {
			return expression_unsupported(checker, view, scope, node, "Or_Return_Results")
		}
		if operand.mode != .Value && operand.mode != .Variable && operand.mode != .Constant && operand.mode != .Immutable_Value {
			return expression_unsupported(checker, view, scope, node, "Or_Return_Plan")
		}
	} else {
		status_index = len(results) - 1
		status = results[status_index]
	}
	status_type = types.get(store, types.resolve_named(store, status))
	if status_type.kind == .Bool {
		test = .Boolean_True
	} else if conversion_nilable(status_type^) {
		test = .Nil
	} else {
		return expression_unsupported(checker, view, scope, node, "Or_Return_Status")
	}
	returnable := false
	if len(checker.results) >= 1 {
		returnable = expression_status_assignable(checker, scope, status, checker.results[len(checker.results) - 1])
	}
	if len(checker.results) > 1 {
		if len(checker.named_results) != len(checker.results) { returnable = false }
		for result in checker.named_results {
			if result == 0 { returnable = false; break }
		}
	}
	if !returnable { return expression_unsupported(checker, view, scope, node, "Or_Return_Result") }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	failure_values := make([]Operand, 1, allocator) or_return
	failure_conversions := make([]Plan_Id, 1, allocator) or_return
	if len(results) == 0 {
		failure_values[0] = Operand(Expression_Ref{view, expression.expr})
	} else {
		failure_values[0] = Operand(Projection{Expression_Ref{view, expression.expr}, u32(status_index)})
	}
	if !expression_propagation_result_matches(checker, status, checker.results[len(checker.results) - 1]) {
		converted := expression_conversion(
			checker,
			view,
			scope,
			expression.expr,
			failure_values[0],
			Expression_Info{type = status, mode = .Value, scope = scope, state = .Checked},
			checker.results[len(checker.results) - 1],
			.Assignment,
		) or_return
		if converted.state == .Invalid { return expression_poison(scope), nil }
		failure_conversions[0] = converted.plan
	}
	failure := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Exit_Plan{kind = .Return, values = failure_values, conversions = failure_conversions})) or_return
	values := make([]Operand, status_index, allocator) or_return
	for index in 0 ..< status_index {
		values[index] = Operand(Projection{Expression_Ref{view, expression.expr}, u32(index)})
	}
	payloads: []types.Type_Id
	if len(values) > 1 {
		payloads = make([]types.Type_Id, len(values), allocator) or_return
		copy(payloads, results[:len(values)])
	}
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(Propagation_Plan{operand = Expression_Ref{view, expression.expr}, test = test, values = values, failure = failure, results = payloads}),
	) or_return
	info = Expression_Info {
		scope = scope,
		state = .Checked,
		plan  = plan,
		mode  = .No_Value,
	}
	if len(values) == 1 { info.type, info.mode = results[0], .Value }
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

// Official check_or_return_expr allows any boolean status into a boolean result, and otherwise
// check_is_assignable_to (a union variant into the procedure's error union).
@(private = "file")
expression_status_assignable :: proc(checker: ^Expression_Checker, scope: Scope_Id, status, result: types.Type_Id) -> bool {
	if expression_propagation_result_matches(checker, status, result) { return true }
	_, diagnostic, failure := check_conversion(
		checker.constants,
		checker.type_checker.store,
		Operand(Expression_Ref{}),
		Expression_Info{type = status, mode = .Value, scope = scope, state = .Checked},
		result,
		.Assignment,
		checker.config,
	)
	return failure == nil && diagnostic == .None
}

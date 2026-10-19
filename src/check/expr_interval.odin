package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

Interval_Plan :: struct {
	lower:     Operand,
	upper:     Operand,
	inclusive: bool,
}

@(private = "package")
expression_interval :: proc(checker: ^Expression_Checker, file_id: File_Id, node: syntax.Node_Index) -> (interval: syntax.Binary_Expr, ok: bool) {
	ast := checker.type_checker.files[file_id].ast
	binary, is_binary := ast.nodes[node].payload.(syntax.Binary_Expr)
	if !is_binary { return {}, false }
	#partial switch binary.op.kind {
	case .Ellipsis, .Range_Full, .Range_Half:
		return binary, true
	}
	return {}, false
}

// Mirrors check_stmt.cpp:1255-1330: bounds take the tag type, the tag must be ordered and the bounds must be ordered.
@(private = "package")
expression_switch_interval :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	interval: syntax.Binary_Expr,
	tag_type: types.Type_Id,
) -> (
	plan: Plan_Id,
	ok: bool,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	bound_type := types.default_type_of_untyped(store, tag_type)
	lower := check_expression(checker, view, scope, interval.left, bound_type) or_return
	upper := check_expression(checker, view, scope, interval.right, bound_type) or_return
	if lower.state == .Invalid || upper.state == .Invalid { return 0, false, nil }
	if !types.is_ordered(store, bound_type) {
		_, err = expression_failure(checker, view, scope, node, .Invalid_Operand)
		return 0, false, err
	}
	if !operand_assignable(checker, view, interval.left, lower, bound_type) || !operand_assignable(checker, view, interval.right, upper, bound_type) {
		_, err = expression_failure(checker, view, scope, node, .Mismatched_Types)
		return 0, false, err
	}
	if lower.constant != 0 && upper.constant != 0 {
		ordered, compare_error := constant_compare_operator(checker.constants, .Lt_Eq, lower.constant, upper.constant)
		if compare_error != nil {
			err = expression_constant_failure(checker, checker.views[view].file, node, compare_error)
			return 0, false, err
		}
		if !constant_pool_get(checker.constants, ordered).value.(bool) {
			_, err = expression_failure(checker, view, scope, node, .Invalid_Operand)
			return 0, false, err
		}
	}
	plan = Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(
			Interval_Plan {
				lower = Operand(Expression_Ref{view, interval.left}),
				upper = Operand(Expression_Ref{view, interval.right}),
				inclusive = interval.op.kind != .Range_Half,
			},
		),
	) or_return
	expression_store(checker, view, node, Expression_Info{type = bound_type, mode = .Value, plan = plan, scope = scope, state = .Checked})
	return plan, true, nil
}

// Mirrors check_expr.cpp:6045-6049 and 5929-5947: an interval key covers each index from its lower bound up to its upper bound, excluding it for ..<.
@(private = "package")
expression_array_key :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file_id: File_Id,
	key: syntax.Node_Index,
	key_type: types.Type_Id,
) -> (
	first, last: i64,
	failed: bool,
	err: Resolve_Error,
) {
	interval, is_interval := expression_interval(checker, file_id, key)
	lower_node, upper_node := key, key
	if is_interval { lower_node, upper_node = interval.left, interval.right }
	lower := check_expression(checker, view, scope, lower_node, key_type) or_return
	if lower.state == .Invalid { return 0, 0, true, nil }
	upper := lower
	if is_interval {
		upper = check_expression(checker, view, scope, upper_node, key_type) or_return
		if upper.state == .Invalid { return 0, 0, true, nil }
	}
	lower_index, lower_ok := expression_constant_integer(checker, lower)
	upper_index, upper_ok := expression_constant_integer(checker, upper)
	if !lower_ok || !upper_ok {
		_, err = expression_failure(checker, view, scope, key, .Invalid_Operand)
		return 0, 0, true, err
	}
	if is_interval && interval.op.kind == .Range_Half { upper_index -= 1 }
	if lower_index > upper_index {
		_, err = expression_failure(checker, view, scope, key, .Invalid_Operand)
		return 0, 0, true, err
	}
	return lower_index, upper_index, false, nil
}

@(private = "file")
expression_constant_integer :: proc(checker: ^Expression_Checker, info: Expression_Info) -> (value: i64, ok: bool) {
	if info.constant == 0 { return 0, false }
	integer, is_integer := constant_pool_get(checker.constants, info.constant).value.(big.Int)
	if !is_integer { return 0, false }
	result, result_error := big.int_get_i64(&integer)
	return result, result_error == .None
}

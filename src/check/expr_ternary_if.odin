package check

import "oc:syntax"
import "oc:types"

@(private = "package")
expression_ternary_if :: proc(
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
	store := checker.type_checker.store
	file := checker.type_checker.files[file_id]
	ternary := syntax.node_payload(file.ast, node, syntax.Ternary_Expr)
	condition := check_expression(checker, view, scope, ternary.cond) or_return
	if condition.state == .Invalid { return expression_poison(scope), nil }
	if !conversion_boolean(types.get(store, conversion_base_type(store, condition.type)).kind) {
		return expression_failure(checker, view, scope, ternary.cond, .Invalid_Operand)
	}
	x_hint := hint
	if hint == 0 && (expression_has_runtime_shift(checker, view, scope, file, ternary.x) or_return) {
		sibling := check_expression(checker, view, scope, ternary.y) or_return
		if sibling.state != .Invalid && !conversion_untyped(types.get(store, sibling.type).kind) { x_hint = sibling.type }
	}
	x := check_expression(checker, view, scope, ternary.x, x_hint) or_return
	if x.state == .Invalid { return expression_poison(scope), nil }
	y_hint := hint
	if y_hint == 0 && !conversion_untyped(types.get(store, x.type).kind) { y_hint = x.type }
	y := check_expression(checker, view, scope, ternary.y, y_hint) or_return
	if y.state == .Invalid { return expression_poison(scope), nil }
	if conversion_untyped(types.get(store, x.type).kind) && !conversion_untyped(types.get(store, y.type).kind) {
		x = check_expression(checker, view, scope, ternary.x, y.type) or_return
	}
	if x.state == .Invalid { return expression_poison(scope), nil }
	if !expression_value(x) || !expression_value(y) { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	if hint == 0 && conversion_untyped(types.get(store, x.type).kind) && conversion_untyped(types.get(store, y.type).kind) {
		target := types.default_type_of_untyped(store, x.type)
		x = check_expression(checker, view, scope, ternary.x, target) or_return
		y = check_expression(checker, view, scope, ternary.y, target) or_return
	}
	if !types.are_identical(store, x.type, y.type) { return expression_failure(checker, view, scope, node, .Mismatched_Types) }
	conversions := Ternary_Conversion_Plan{}
	program: Checked_Program
	expression_checker_publish(checker, &program)
	if stored := expression_info(&program, view, ternary.x); x.plan != stored.plan { conversions.x = x.plan }
	if stored := expression_info(&program, view, ternary.y); y.plan != stored.plan { conversions.y = y.plan }
	plan := Plan_Id(0)
	if conversions.x != 0 || conversions.y != 0 {
		plan = Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(conversions)) or_return
	}
	return Expression_Info{type = x.type, mode = .Value, scope = scope, state = .Checked, plan = plan}, nil
}

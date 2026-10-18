package check

import "oc:syntax"
import "oc:types"

@(private = "package")
expression_assert :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	if len(arguments) < 1 || len(arguments) > 2 {
		return expression_unsupported(checker, view, scope, node, "Assert_Arguments")
	}
	condition := check_expression(checker, view, scope, arguments[0]) or_return
	if condition.state == .Invalid { return expression_poison(scope), nil }
	if condition.mode != .Constant ||
	   !conversion_boolean(types.get(checker.type_checker.store, conversion_base_type(checker.type_checker.store, condition.type)).kind) {
		return expression_failure(checker, view, scope, arguments[0], .Expected_Boolean_Constant)
	}
	if len(arguments) == 2 {
		message := arguments[1]
		if file.ast.nodes[message].kind != .Basic_Lit || syntax.node_payload(file.ast, message, syntax.Basic_Lit).kind != .String {
			return expression_failure(checker, view, scope, message, .Invalid_Operand)
		}
	}
	value, is_bool := constant_pool_get(checker.constants, condition.constant).value.(bool)
	if !is_bool || !value { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	return condition, nil
}

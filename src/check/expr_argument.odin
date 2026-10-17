package check

import "oc:syntax"
import "oc:types"

// A runtime argument converts to its parameter type through its own conversion plan, which the call retains; the
// argument keeps its unconverted type. Constants and expressions that need the parameter type to be checked take it as a hint.
@(private = "package")
expression_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	target: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	#partial switch file.ast.nodes[node].kind {
	case .Implicit_Selector_Expr, .Comp_Lit, .Ternary_When_Expr, .Ternary_If_Expr:
		return check_expression(checker, view, scope, node, target)
	}
	info = check_expression(checker, view, scope, node) or_return
	if info.state == .Invalid || info.type == target { return info, nil }
	if info.mode == .Constant { return check_expression(checker, view, scope, node, target) }
	return expression_conversion(checker, view, scope, node, Operand(Expression_Ref{view, node}), info, target, .Assignment)
}

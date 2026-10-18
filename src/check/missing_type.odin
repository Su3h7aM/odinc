package check

import "core:reflect"
import "oc:syntax"
import "oc:types"

// A value whose type was never set would reach the type store as TYPE_NONE. It is reported at its node instead.
// Procedures without a signature (generic ones) keep TYPE_NONE by design and are not reported.
@(private = "package")
expression_missing_type :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	info: Expression_Info,
) -> (
	failed: Expression_Info,
	reported: bool,
	err: Resolve_Error,
) {
	if info.state == .Invalid || info.type != types.TYPE_NONE { return {}, false, nil }
	#partial switch info.mode {
	case .Value, .Variable, .Immutable_Value, .Constant, .Optional_Ok:
	case:
		return {}, false, nil
	}
	if info.entity != 0 && entity_get(checker.type_checker.resolver.scopes, info.entity).kind == .Procedure { return {}, false, nil }
	file := checker.views[view].file
	failed, err = expression_failure(checker, view, scope, node, .Missing_Type, reflect.enum_string(checker.type_checker.files[file].ast.nodes[node].kind))
	return failed, true, err
}

package check

import "../syntax"

// Official #config(NAME, default) yields the default's constant unless a -define supplies NAME.
// The driver has no -define input yet, so the default always applies.
@(private = "package")
expression_config :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	if len(arguments) != 2 || file.ast.nodes[arguments[0]].kind != .Ident {
		return expression_unsupported(checker, view, scope, node, "Config_Arguments")
	}
	defaulted := check_expression(checker, view, scope, arguments[1]) or_return
	if defaulted.mode != .Constant { return expression_unsupported(checker, view, scope, node, "Config_Default") }
	return defaulted, nil
}

package check

import "oc:syntax"

@(private = "package")
expression_panic :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 { return expression_unsupported(checker, view, scope, node, "Panic_Arguments") }
	argument := check_expression(checker, view, scope, arguments[0]) or_return
	if argument.state == .Invalid { return expression_poison(scope), nil }
	if argument.mode != .Constant { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	message, is_string := constant_pool_get(checker.constants, argument.constant).value.(string)
	if !is_string { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	return expression_failure(checker, view, scope, node, .Compile_Time_Panic, message)
}

check_package_directives :: proc(checker: ^Expression_Checker) -> (valid: bool, err: Resolve_Error) {
	collection := checker.type_checker.collection
	valid = true
	for index in 0 ..< len(collection.pending) {
		pending := collection.pending[index]
		if pending.handled || pending.kind != .Directive { continue }
		file := checker.type_checker.files[pending.declaration.file]
		statement := syntax.node_payload(file.ast, pending.declaration.node, syntax.Expr_Stmt)
		if file.ast.nodes[statement.expr].kind != .Call_Expr { continue }
		call := syntax.node_payload(file.ast, statement.expr, syntax.Call_Expr)
		if file.ast.nodes[call.expr].kind != .Basic_Directive { continue }
		view := expression_file_view(checker, pending.declaration.file) or_return
		info := check_expression(checker, view, file.scope, statement.expr) or_return
		if info.state == .Invalid { valid = false }
		collection.pending[index].handled = true
	}
	return valid, nil
}

package check

import "oc:syntax"
import "oc:types"

// `#defined(name)` is an untyped bool constant telling whether `name` is declared in scope. An undeclared name is not an error (check_builtin.cpp:2947-2965).
@(private = "package")
expression_defined :: proc(
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
	if len(arguments) != 1 { return expression_unsupported(checker, view, scope, node, "Defined_Arity") }
	argument := type_unparen(file, arguments[0])
	if file.ast.nodes[argument].kind != .Ident { return expression_unsupported(checker, view, scope, node, "Defined_Operand") }
	declared, _ := scope_lookup(checker.type_checker.resolver.scopes, scope, expression_text(file, argument))
	constant, failure := constant_pool_intern_bool(checker.constants, declared != 0, types.TYPE_UNTYPED_BOOL)
	if failure != nil { return {}, expression_constant_failure(checker, checker.views[view].file, node, failure) }
	return Expression_Info{scope = scope, mode = .Constant, type = types.TYPE_UNTYPED_BOOL, constant = constant, state = .Checked}, nil
}

package check

import "core:os"
import "core:path/filepath"
import "oc:syntax"
import "oc:types"

// Official #exists(path): a constant string names a file, relative to the directory of the calling file unless absolute.
@(private = "package")
expression_exists :: proc(
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
	if len(arguments) != 1 { return expression_unsupported(checker, view, scope, node, "Exists_Arguments") }
	argument := check_expression(checker, view, scope, arguments[0]) or_return
	if argument.state == .Invalid { return expression_poison(scope), nil }
	if argument.mode != .Constant { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	path, is_string := constant_pool_get(checker.constants, argument.constant).value.(string)
	if !is_string { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	if !filepath.is_abs(path) {
		directory := filepath.dir(checker.type_checker.files[file_id].path)
		joined, join_error := filepath.join({directory, path}, context.temp_allocator)
		if join_error != nil { return {}, join_error }
		path = joined
	}
	constant, constant_error := constant_pool_intern_bool(checker.constants, os.exists(path), types.TYPE_UNTYPED_BOOL)
	if constant_error != nil {
		expression_constant_failure(checker, file_id, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = types.TYPE_UNTYPED_BOOL, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

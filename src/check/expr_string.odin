package check

import "core:strings"
import "oc:syntax"
import "oc:types"

// A double-quoted literal without escapes is a constant of type string. Escapes and other forms are unsupported.
@(private = "package")
expression_string_literal :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	text := expression_text(file, node)
	if len(text) < 2 || text[0] != '"' || text[len(text) - 1] != '"' || strings.starts_with(text, `"""`) || strings.contains_rune(text, '\\') {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	string_type := types.intern(checker.type_checker.store, types.Type{kind = .String})
	constant, constant_error := constant_pool_intern_string(checker.constants, text[1:len(text) - 1], string_type)
	if constant_error != nil {
		expression_constant_failure(checker, file_id, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = string_type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

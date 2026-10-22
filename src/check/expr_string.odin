package check

import "oc:syntax"
import "oc:types"

// A string literal is a constant of the hinted string type, when provided.
@(private = "package")
expression_string_literal :: proc(
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
	file := checker.type_checker.files[file_id]
	text := expression_text(file, node)
	value, decoded, decode_error := literal_string_value(text, context.temp_allocator)
	if decode_error != nil { return {}, decode_error }
	if !decoded { return expression_failure(checker, view, scope, node, .Invalid_Literal) }
	literal_type := types.TYPE_UNTYPED_STRING
	if hint != 0 {
		kind := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, hint)).kind
		if kind == .String || kind == .String16 || kind == .CString || kind == .CString16 { literal_type = hint }
	}
	constant, constant_error := constant_pool_intern_string(checker.constants, value, literal_type)
	if constant_error != nil {
		expression_constant_failure(checker, file_id, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = literal_type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

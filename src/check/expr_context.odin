package check

import "oc:syntax"

// `context` has type runtime.Context and mode Context: its address is the current context binding during lowering.
@(private = "package")
expression_context :: proc(
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
	if syntax.node_payload(file.ast, node, syntax.Implicit).kind != .Context {
		return expression_unsupported(checker, view, scope, node, "Implicit_Kind")
	}
	collection := checker.type_checker.collection
	scopes := checker.type_checker.resolver.scopes
	if collection == nil || collection.runtime_scope == 0 { return expression_unsupported(checker, view, scope, node, "Context_Runtime") }
	entity := scope_lookup_current(scopes, collection.runtime_scope, "Context")
	if entity == 0 { return expression_unsupported(checker, view, scope, node, "Context_Type") }
	if _, resolve_error := resolve_entity(checker.type_checker.resolver, entity); resolve_error != nil { return {}, resolve_error }
	return Expression_Info{type = entity_get(scopes, entity).type, mode = .Context, scope = scope, state = .Checked}, nil
}

package check

import "oc:syntax"
import "oc:types"

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
	if !context_defined(checker, scope) {
		return expression_failure(checker, view, scope, node, .Undefined_Context, "'context' has not been defined within this scope")
	}
	collection := checker.type_checker.collection
	scopes := checker.type_checker.resolver.scopes
	if collection == nil || collection.runtime_scope == 0 { return expression_unsupported(checker, view, scope, node, "Context_Runtime") }
	entity := scope_lookup_current(scopes, collection.runtime_scope, "Context")
	if entity == 0 { return expression_unsupported(checker, view, scope, node, "Context_Type") }
	if _, resolve_error := resolve_entity(checker.type_checker.resolver, entity); resolve_error != nil { return {}, resolve_error }
	return Expression_Info{type = entity_get(scopes, entity).type, mode = .Context, scope = scope, state = .Checked}, nil
}

// Official ScopeFlag_ContextDefined: only odin-convention procedures, or procedures that assign `context`, can name it.
@(private = "package")
expression_require_call_context :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	convention: types.Calling_Convention,
) -> (
	allowed: bool,
	err: Resolve_Error,
) {
	// Official check_call: an odin-convention callee receives the caller's implicit context.
	if convention != .Odin || context_defined(checker, scope) { return true, nil }
	_, failure_error := expression_failure(
		checker,
		view,
		scope,
		node,
		.Undefined_Context,
		"'context' has not been defined within this scope, but is required for this procedure call",
	)
	if failure_error != nil { return false, failure_error }
	return false, nil
}

// Official ScopeFlag_ContextDefined: only odin-convention procedures, or procedures that assign `context`, can name it.
@(private = "package")
context_defined :: proc(checker: ^Expression_Checker, scope: Scope_Id) -> bool {
	scopes := checker.type_checker.resolver.scopes
	for current := scope; current != 0; current = scope_get(scopes, current).parent {
		if scope_get(scopes, current).kind != .Procedure { continue }
		procedure, is_procedure := entity_get(scopes, scope_get(scopes, current).owner).data.(Procedure_Data)
		return !is_procedure || procedure.convention == .Odin || procedure.assigns_context
	}
	return true
}

@(private = "package")
mark_context_assignment :: proc(checker: ^Expression_Checker, scope: Scope_Id) {
	scopes := checker.type_checker.resolver.scopes
	for current := scope; current != 0; current = scope_get(scopes, current).parent {
		if scope_get(scopes, current).kind != .Procedure { continue }
		procedure, is_procedure := &entity_get(scopes, scope_get(scopes, current).owner).data.(Procedure_Data)
		if is_procedure { procedure.assigns_context = true }
		return
	}
}

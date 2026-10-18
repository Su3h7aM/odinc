package check

import "oc:syntax"
import "oc:types"

// A call to a procedure tagged #optional_ok or #optional_allocator_error yields its first result alone in a
// single-value context. The plan keeps every result, so tuple contexts still read the full list.
@(private = "package")
expression_optional_result :: proc(checker: ^Expression_Checker, info: Expression_Info) -> Expression_Info {
	if info.plan == 0 { return info }
	call, is_call := checker.plans[info.plan].(Call_Plan)
	if !is_call || len(call.results) < 2 { return info }
	signature: types.Type_Id
	if call.entity != 0 {
		signature = entity_get(checker.type_checker.resolver.scopes, call.entity).type
	} else {
		callee, is_expression := call.callee.(Expression_Ref)
		if !is_expression { return info }
		callee_view := checker.views[callee.view]
		index := int(callee.node - callee_view.first_node)
		if index < 0 || index >= len(callee_view.nodes.types) { return info }
		signature = callee_view.nodes.types[index]
	}
	signature = types.resolve_named(checker.type_checker.store, signature)
	if signature == types.TYPE_NONE || signature == types.TYPE_POISON { return info }
	procedure_type := types.get(checker.type_checker.store, signature)
	if procedure_type.kind != .Procedure || !procedure_type.optional_result { return info }
	result := info
	result.type = call.results[0]
	result.mode = .Optional_Ok
	return result
}

// The single value of an expression: the first result of an optional-result call, otherwise the expression itself.
@(private = "package")
expression_value_operand :: proc(checker: ^Expression_Checker, view: View_Id, node: syntax.Node_Index, info: Expression_Info) -> Operand {
	if info.mode == .Optional_Ok && info.plan != 0 {
		if call, is_call := checker.plans[info.plan].(Call_Plan); is_call && len(call.results) > 1 {
			return Operand(Projection{Expression_Ref{view, node}, 0})
		}
	}
	return Operand(Expression_Ref{view, node})
}

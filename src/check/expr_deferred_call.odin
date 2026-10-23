package check

import "oc:syntax"

Deferred_Site :: struct {
	view:   View_Id,
	node:   syntax.Node_Index,
	reason: string,
}

DEFERRED_IN_LOGICAL :: "Procedure calls that have an associated deferred procedure are not allowed within logical binary expressions"
DEFERRED_IN_TERNARY :: "Procedure calls that have an associated deferred procedure are not allowed within ternary expressions"
DEFERRED_IN_OR_ELSE :: "Procedure calls that have an associated deferred procedure are not allowed on the right-hand side of 'or_else'"
DEFERRED_IN_CASE :: "Procedure calls that have an associated deferred procedure are not allowed within case clauses"

// Operands that might not be evaluated cannot call a procedure with a deferred procedure. Calls are only
// known to defer once the deferred targets are backfilled, so the operands are recorded and judged at publish.
@(private = "package")
expression_record_deferred_sites :: proc(checker: ^Expression_Checker, view: View_Id, file: ^File, node: syntax.Node_Index) -> Resolve_Error {
	#partial switch file.ast.nodes[node].kind {
	case .Binary_Expr:
		binary := syntax.node_payload(file.ast, node, syntax.Binary_Expr)
		if binary.op.kind != .Cmp_And && binary.op.kind != .Cmp_Or { return nil }
		append(&checker.deferred_sites, Deferred_Site{view, binary.left, DEFERRED_IN_LOGICAL}) or_return
		append(&checker.deferred_sites, Deferred_Site{view, binary.right, DEFERRED_IN_LOGICAL}) or_return
	case .Ternary_If_Expr:
		ternary := syntax.node_payload(file.ast, node, syntax.Ternary_Expr)
		append(&checker.deferred_sites, Deferred_Site{view, ternary.x, DEFERRED_IN_TERNARY}) or_return
		append(&checker.deferred_sites, Deferred_Site{view, ternary.y, DEFERRED_IN_TERNARY}) or_return
	case .Or_Else_Expr:
		append(&checker.deferred_sites, Deferred_Site{view, syntax.node_payload(file.ast, node, syntax.Or_Else_Expr).y, DEFERRED_IN_OR_ELSE}) or_return
	}
	return nil
}

@(private = "package")
expression_report_deferred_sites :: proc(checker: ^Expression_Checker) -> Resolve_Error {
	reported := make(map[Deferred_Site]struct{}, context.temp_allocator)
	for site in checker.deferred_sites {
		if site in reported || !expression_contains_deferred_call(checker, site.view, site.node) { continue }
		reported[site] = {}
		file_id := checker.views[site.view].file
		span := checker.type_checker.files[file_id].ast.nodes[site.node]
		append(&checker.diagnostics, Expression_Diagnostic{kind = .Message, source = {file_id, span.start, span.end}, reason = site.reason}) or_return
	}
	clear(&checker.deferred_sites)
	return nil
}

@(private = "file")
expression_contains_deferred_call :: proc(checker: ^Expression_Checker, view: View_Id, node: syntax.Node_Index) -> bool {
	if node == 0 { return false }
	file := checker.type_checker.files[checker.views[view].file]
	#partial switch file.ast.nodes[node].kind {
	case .Call_Expr:
		if call, is_call := expression_call_plan(checker, view, node); is_call && call.deferred != 0 { return true }
		return expression_contains_deferred_call(checker, view, syntax.node_payload(file.ast, node, syntax.Call_Expr).expr)
	case .Paren_Expr:
		return expression_contains_deferred_call(checker, view, syntax.node_payload(file.ast, node, syntax.Paren_Expr).expr)
	case .Unary_Expr:
		return expression_contains_deferred_call(checker, view, syntax.node_payload(file.ast, node, syntax.Unary_Expr).expr)
	case .Binary_Expr:
		binary := syntax.node_payload(file.ast, node, syntax.Binary_Expr)
		return expression_contains_deferred_call(checker, view, binary.left) || expression_contains_deferred_call(checker, view, binary.right)
	case .Ternary_If_Expr, .Ternary_When_Expr:
		ternary := syntax.node_payload(file.ast, node, syntax.Ternary_Expr)
		return(
			expression_contains_deferred_call(checker, view, ternary.cond) ||
			expression_contains_deferred_call(checker, view, ternary.x) ||
			expression_contains_deferred_call(checker, view, ternary.y) \
		)
	case .Or_Else_Expr:
		fallback := syntax.node_payload(file.ast, node, syntax.Or_Else_Expr)
		return expression_contains_deferred_call(checker, view, fallback.x) || expression_contains_deferred_call(checker, view, fallback.y)
	case .Or_Return_Expr:
		return expression_contains_deferred_call(checker, view, syntax.node_payload(file.ast, node, syntax.Or_Return_Expr).expr)
	case .Index_Expr:
		return expression_contains_deferred_call(checker, view, syntax.node_payload(file.ast, node, syntax.Index_Expr).expr)
	case .Deref_Expr:
		return expression_contains_deferred_call(checker, view, syntax.node_payload(file.ast, node, syntax.Deref_Expr).expr)
	case .Slice_Expr:
		return expression_contains_deferred_call(checker, view, syntax.node_payload(file.ast, node, syntax.Slice_Expr).expr)
	case .Type_Assertion:
		return expression_contains_deferred_call(checker, view, syntax.node_payload(file.ast, node, syntax.Type_Assertion).expr)
	case .Type_Cast:
		return expression_contains_deferred_call(checker, view, syntax.node_payload(file.ast, node, syntax.Type_Cast).expr)
	case .Auto_Cast:
		return expression_contains_deferred_call(checker, view, syntax.node_payload(file.ast, node, syntax.Auto_Cast).expr)
	}
	return false
}

@(private = "file")
expression_call_plan :: proc(checker: ^Expression_Checker, view: View_Id, node: syntax.Node_Index) -> (call: Call_Plan, ok: bool) {
	info := expression_stored_info(checker, view, node)
	if info.plan == 0 || int(info.plan) >= len(checker.plans) { return {}, false }
	call, ok = checker.plans[info.plan].(Call_Plan)
	return
}

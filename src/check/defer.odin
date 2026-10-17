package check

import "core:mem"
import "oc:syntax"

// Checks a defer statement's body in its own control context and registers it for the procedure.
// Official: check_stmt.cpp DeferStmt case (2930-2995): declarations are rejected, and the body
// is checked with in_defer set, so return and labelled branches fail and outer loops are not targets.
@(private = "package")
expression_defer :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	statement := syntax.node_payload(file.ast, node, syntax.Defer_Stmt).stmt
	if file.ast.nodes[statement].kind == .Value_Decl {
		expression_failure(checker, view, scope, node, .Unsupported) or_return
		return nil
	}
	outer_control := checker.control
	checker.control = make([dynamic]Control_Frame, outer_control.allocator) or_return
	checker.defer_depth += 1
	defer {
		checker.defer_depth -= 1
		delete(checker.control)
		checker.control = outer_control
	}
	expression_statement(checker, view, file_id, scope, statement) or_return
	append(&checker.defers, Defer_Registration{scope = scope, statement = Node_Ref{file_id, statement}}) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

// Moves the defers registered since first into the procedure's arena slice and truncates the list.
@(private = "package")
expression_take_defers :: proc(checker: ^Expression_Checker, first: int) -> (defers: []Defer_Registration, err: Resolve_Error) {
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	defers = make([]Defer_Registration, len(checker.defers) - first, allocator) or_return
	copy(defers, checker.defers[first:])
	resize(&checker.defers, first) or_return
	return defers, nil
}

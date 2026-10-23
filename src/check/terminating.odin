package check

import "oc:syntax"
import "oc:types"

// Ports official check_is_terminating and check_has_break (check_stmt.cpp). `or_break` operands are not searched for breaks.
@(private = "package")
body_terminates :: proc(checker: ^Expression_Checker, view: View_Id, file: ^File, node: syntax.Node_Index) -> bool {
	return statement_terminates(checker, view, file, node, "")
}

@(private = "file")
statement_list_terminates :: proc(checker: ^Expression_Checker, view: View_Id, file: ^File, statements: []syntax.Node_Index, label: string) -> bool {
	#reverse for statement in statements {
		kind := file.ast.nodes[statement].kind
		if kind == .Empty_Stmt { continue }
		if kind == .Value_Decl && !syntax.node_payload(file.ast, statement, syntax.Value_Decl).is_mutable { continue }
		if statement_diverges(checker, view, file, statement) { return true }
		return statement_terminates(checker, view, file, statement, label)
	}
	return false
}

@(private = "file")
statement_diverges :: proc(checker: ^Expression_Checker, view: View_Id, file: ^File, statement: syntax.Node_Index) -> bool {
	if file.ast.nodes[statement].kind != .Expr_Stmt { return false }
	expression := syntax.node_payload(file.ast, statement, syntax.Expr_Stmt).expr
	for file.ast.nodes[expression].kind == .Paren_Expr {
		expression = syntax.node_payload(file.ast, expression, syntax.Paren_Expr).expr
	}
	if file.ast.nodes[expression].kind != .Call_Expr { return false }
	plan_id := expression_stored_info(checker, view, expression).plan
	if plan_id == 0 { return false }
	store := checker.type_checker.store
	#partial switch plan in checker.plans[plan_id] {
	case Builtin_Plan:
		#partial switch checker.builtin_kinds[plan.builtin] {
		case .Trap, .Unreachable, .Debug_Trap:
			return true
		}
	case Call_Plan:
		callee := syntax.node_payload(file.ast, expression, syntax.Call_Expr).expr
		type := expression_stored_info(checker, view, callee).type
		if type == 0 && plan.entity != 0 { type = entity_get(checker.type_checker.resolver.scopes, plan.entity).type }
		if type == 0 { return false }
		descriptor := types.get(store, types.resolve_named(store, type))
		return descriptor.kind == .Procedure && descriptor.diverging
	}
	return false
}

@(private = "file")
statement_terminates :: proc(checker: ^Expression_Checker, view: View_Id, file: ^File, node: syntax.Node_Index, label: string) -> bool {
	if node == 0 { return false }
	ast := file.ast
	#partial switch ast.nodes[node].kind {
	case .Return_Stmt:
		return true
	case .Tag_Stmt:
		return statement_terminates(checker, view, file, syntax.node_payload(ast, node, syntax.Tag_Stmt).stmt, label)
	case .Block_Stmt:
		block := syntax.node_payload(ast, node, syntax.Block_Stmt)
		statements := syntax.node_list(ast, block.stmts)
		if !statement_list_terminates(checker, view, file, statements, label) { return false }
		if block.label != 0 { return statement_list_terminates(checker, view, file, statements, expression_label(file, block.label)) }
		return true
	case .Expr_Stmt:
		return false
	case .Branch_Stmt:
		return syntax.node_payload(ast, node, syntax.Branch_Stmt).token.kind == .Fallthrough
	case .If_Stmt:
		statement := syntax.node_payload(ast, node, syntax.If_Stmt)
		return(
			statement.else_stmt != 0 &&
			statement_terminates(checker, view, file, statement.body, label) &&
			statement_terminates(checker, view, file, statement.else_stmt, label) \
		)
	case .When_Stmt:
		statement := syntax.node_payload(ast, node, syntax.When_Stmt)
		if statement.body != 0 && expression_stored_info(checker, view, statement.body).state == .Inactive {
			return statement_terminates(checker, view, file, statement.else_stmt, label)
		}
		return statement_terminates(checker, view, file, statement.body, label)
	case .For_Stmt:
		statement := syntax.node_payload(ast, node, syntax.For_Stmt)
		if statement.cond != 0 || statement_has_break(file, statement.body, label, true) { return false }
		if statement.label != 0 { return !statement_has_break(file, statement.body, expression_label(file, statement.label), false) }
		return true
	case .Switch_Stmt:
		return clauses_terminate(checker, view, file, syntax.node_payload(ast, node, syntax.Switch_Stmt).body, label)
	case .Type_Switch_Stmt:
		return clauses_terminate(checker, view, file, syntax.node_payload(ast, node, syntax.Type_Switch_Stmt).body, label)
	}
	return false
}

@(private = "file")
clauses_terminate :: proc(checker: ^Expression_Checker, view: View_Id, file: ^File, body: syntax.Node_Index, label: string) -> bool {
	has_default := false
	for clause_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, body, syntax.Block_Stmt).stmts) {
		clause := syntax.node_payload(file.ast, clause_node, syntax.Case_Clause)
		if clause.list.count == 0 { has_default = true }
		statements := syntax.node_list(file.ast, clause.body)
		if !statement_list_terminates(checker, view, file, statements, label) || statements_have_break(file, statements, label, true) { return false }
	}
	return has_default
}

@(private = "file")
statements_have_break :: proc(file: ^File, statements: []syntax.Node_Index, label: string, implicit: bool) -> bool {
	for statement in statements {
		if statement_has_break(file, statement, label, implicit) { return true }
	}
	return false
}

@(private = "file")
statement_has_break :: proc(file: ^File, node: syntax.Node_Index, label: string, implicit: bool) -> bool {
	if node == 0 { return false }
	ast := file.ast
	#partial switch ast.nodes[node].kind {
	case .Branch_Stmt:
		branch := syntax.node_payload(ast, node, syntax.Branch_Stmt)
		if branch.token.kind != .Break { return false }
		if branch.label == 0 { return implicit }
		return expression_label(file, branch.label) == label
	case .Defer_Stmt:
		return statement_has_break(file, syntax.node_payload(ast, node, syntax.Defer_Stmt).stmt, label, implicit)
	case .Tag_Stmt:
		return statement_has_break(file, syntax.node_payload(ast, node, syntax.Tag_Stmt).stmt, label, implicit)
	case .Block_Stmt:
		return statements_have_break(file, syntax.node_list(ast, syntax.node_payload(ast, node, syntax.Block_Stmt).stmts), label, implicit)
	case .If_Stmt:
		statement := syntax.node_payload(ast, node, syntax.If_Stmt)
		return(
			statement_has_break(file, statement.init, label, implicit) ||
			statement_has_break(file, statement.body, label, implicit) ||
			statement_has_break(file, statement.else_stmt, label, implicit) \
		)
	case .Case_Clause:
		return statements_have_break(file, syntax.node_list(ast, syntax.node_payload(ast, node, syntax.Case_Clause).body), label, implicit)
	case .Switch_Stmt:
		return label != "" && statement_has_break(file, syntax.node_payload(ast, node, syntax.Switch_Stmt).body, label, false)
	case .Type_Switch_Stmt:
		return label != "" && statement_has_break(file, syntax.node_payload(ast, node, syntax.Type_Switch_Stmt).body, label, false)
	case .For_Stmt:
		statement := syntax.node_payload(ast, node, syntax.For_Stmt)
		return(
			statement_has_break(file, statement.init, label, implicit) ||
			statement_has_break(file, statement.post, label, implicit) ||
			label != "" && statement_has_break(file, statement.body, label, false) \
		)
	case .Range_Stmt:
		return label != "" && statement_has_break(file, syntax.node_payload(ast, node, syntax.Range_Stmt).body, label, false)
	}
	return false
}

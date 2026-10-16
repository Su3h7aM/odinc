package check

import "oc:syntax"
import "oc:types"

Control_Frame :: struct {
	node:      syntax.Node_Index,
	label:     string,
	is_loop:   bool,
	is_switch: bool,
}

@(private = "package")
expression_switch :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	statement := syntax.node_payload(file.ast, node, syntax.Switch_Stmt)
	switch_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block)
	if scope_error != nil { return binding_resolve_error(scope_error) }
	if statement.init != 0 { expression_statement(checker, view, file_id, switch_scope, statement.init) or_return }
	tag_type: types.Type_Id
	if statement.cond != 0 {
		tag := check_expression(checker, view, switch_scope, statement.cond) or_return
		if tag.state == .Invalid { return nil }
		tag_type = tag.type
	}
	append(&checker.control, Control_Frame{node = node, label = expression_label(file, statement.label), is_switch = true}) or_return
	defer pop(&checker.control)
	clauses := syntax.node_list(file.ast, syntax.node_payload(file.ast, statement.body, syntax.Block_Stmt).stmts)
	for clause in clauses {
		case_clause := syntax.node_payload(file.ast, clause, syntax.Case_Clause)
		for value in syntax.node_list(file.ast, case_clause.list) {
			if statement.cond != 0 {
				_ = check_expression(checker, view, switch_scope, value, tag_type) or_return
			} else {
				expression_condition(checker, view, switch_scope, value) or_return
			}
		}
		clause_scope, clause_error := scope_create(checker.type_checker.resolver.scopes, switch_scope, .Block)
		if clause_error != nil { return binding_resolve_error(clause_error) }
		for statement_node in syntax.node_list(file.ast, case_clause.body) {
			expression_statement(checker, view, file_id, clause_scope, statement_node) or_return
		}
		expression_store(checker, view, clause, Expression_Info{scope = clause_scope, state = .Checked})
	}
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

@(private = "package")
expression_if :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	statement := syntax.node_payload(file.ast, node, syntax.If_Stmt)
	if_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block)
	if scope_error != nil { return binding_resolve_error(scope_error) }
	if statement.init != 0 { expression_statement(checker, view, file_id, if_scope, statement.init) or_return }
	expression_condition(checker, view, if_scope, statement.cond) or_return
	append(&checker.control, Control_Frame{node = node, label = expression_label(file, statement.label)}) or_return
	defer pop(&checker.control)
	expression_statement(checker, view, file_id, if_scope, statement.body) or_return
	if statement.else_stmt != 0 { expression_statement(checker, view, file_id, if_scope, statement.else_stmt) or_return }
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

@(private = "package")
expression_for :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	statement := syntax.node_payload(file.ast, node, syntax.For_Stmt)
	loop_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block)
	if scope_error != nil { return binding_resolve_error(scope_error) }
	if statement.init != 0 { expression_statement(checker, view, file_id, loop_scope, statement.init) or_return }
	if statement.cond != 0 { expression_condition(checker, view, loop_scope, statement.cond) or_return }
	if .No_Bounds_Check in file.ast.nodes[node].flags { checker.unchecked_depth += 1 }
	defer {
		if .No_Bounds_Check in file.ast.nodes[node].flags { checker.unchecked_depth -= 1 }
	}
	append(&checker.control, Control_Frame{node = node, label = expression_label(file, statement.label), is_loop = true}) or_return
	defer pop(&checker.control)
	expression_statement(checker, view, file_id, loop_scope, statement.body) or_return
	if statement.post != 0 { expression_statement(checker, view, file_id, loop_scope, statement.post) or_return }
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

@(private = "package")
expression_when :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	statement := syntax.node_payload(file.ast, node, syntax.When_Stmt)
	condition := check_expression(checker, view, scope, statement.cond) or_return
	if condition.state == .Invalid { return nil }
	value, is_bool := constant_pool_get(checker.constants, condition.constant).value.(bool)
	if condition.mode != .Constant || !is_bool {
		expression_failure(checker, view, scope, statement.cond, .Unsupported) or_return
		return nil
	}
	taken, skipped := statement.body, statement.else_stmt
	if !value { taken, skipped = statement.else_stmt, statement.body }
	if taken != 0 {
		expression_statement(checker, view, file_id, scope, taken) or_return
		expression_store(checker, view, taken, Expression_Info{scope = scope, state = .Checked})
	}
	if skipped != 0 { expression_store(checker, view, skipped, Expression_Info{scope = scope, state = .Inactive}) }
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

@(private = "package")
expression_branch :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	statement := syntax.node_payload(file.ast, node, syntax.Branch_Stmt)
	exit_kind: Exit_Kind
	#partial switch statement.token.kind {
	case .Break:
		exit_kind = .Break
	case .Continue:
		exit_kind = .Continue
	case:
		expression_failure(checker, view, scope, node, .Unsupported) or_return
		return nil
	}
	label := expression_label(file, statement.label)
	for index := len(checker.control) - 1; index >= 0; index -= 1 {
		frame := checker.control[index]
		if label != "" && frame.label != label { continue }
		if label == "" && !frame.is_loop && (exit_kind == .Continue || !frame.is_switch) { continue }
		if exit_kind == .Continue && !frame.is_loop { break }
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Exit_Plan{kind = exit_kind, target = Node_Ref{file_id, frame.node}})) or_return
		expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
		return nil
	}
	expression_failure(checker, view, scope, node, .Unsupported) or_return
	return nil
}

@(private = "package")
expression_labeled_block :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	block := syntax.node_payload(file.ast, node, syntax.Block_Stmt)
	if block.label == 0 { return expression_block(checker, view, file_id, scope, node) }
	append(&checker.control, Control_Frame{node = node, label = expression_label(file, block.label)}) or_return
	defer pop(&checker.control)
	return expression_block(checker, view, file_id, scope, node)
}

@(private = "file")
expression_condition :: proc(checker: ^Expression_Checker, view: View_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	condition := check_expression(checker, view, scope, node) or_return
	if condition.state == .Invalid { return nil }
	if !conversion_boolean(types.get(checker.type_checker.store, condition.type).kind) {
		expression_failure(checker, view, scope, node, .Mismatched_Types) or_return
	}
	return nil
}

@(private = "file")
expression_label :: proc(file: ^File, label: syntax.Node_Index) -> string {
	if label == 0 { return "" }
	return expression_text(file, label)
}

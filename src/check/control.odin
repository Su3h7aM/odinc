package check

import "core:mem"
import "oc:syntax"
import "oc:types"

Control_Frame :: struct {
	node:       syntax.Node_Index,
	label:      string,
	is_loop:    bool,
	is_switch:  bool,
	is_barrier: bool,
}

@(private = "package")
expression_switch :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	statement := syntax.node_payload(file.ast, node, syntax.Switch_Stmt)
	switch_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block)
	if scope_error != nil { return binding_resolve_error(scope_error) }
	if statement.init != 0 { expression_statement(checker, view, file_id, switch_scope, statement.init) or_return }
	tag_type: types.Type_Id
	tag_entity: Entity_Id
	comparison_name: string
	if statement.cond != 0 {
		tag := check_expression(checker, view, switch_scope, statement.cond) or_return
		if tag.state == .Invalid { return nil }
		tag_type = tag.type
		tag_error: Resolve_Error
		tag_entity, comparison_name, tag_error = expression_switch_tag(checker, switch_scope, tag_type)
		if tag_error != nil { return tag_error }
	}
	comparisons := make([dynamic]Plan_Id, mem.dynamic_arena_allocator(&checker.arena)) or_return
	append(&checker.control, Control_Frame{node = node, label = expression_label(file, statement.label), is_switch = true}) or_return
	defer pop(&checker.control)
	clauses := syntax.node_list(file.ast, syntax.node_payload(file.ast, statement.body, syntax.Block_Stmt).stmts)
	for clause in clauses {
		case_clause := syntax.node_payload(file.ast, clause, syntax.Case_Clause)
		for value in syntax.node_list(file.ast, case_clause.list) {
			if statement.cond != 0 {
				if interval, is_interval := expression_interval(checker, file_id, value); is_interval {
					plan, interval_ok, interval_error := expression_switch_interval(checker, view, switch_scope, value, interval, tag_type)
					if interval_error != nil { return interval_error }
					if interval_ok && tag_entity != 0 { append(&comparisons, plan) or_return }
					continue
				}
				_ = check_expression(checker, view, switch_scope, value, tag_type) or_return
				if tag_entity != 0 {
					plan, supported, plan_error := runtime_comparison_plan(checker, comparison_name, Operand(tag_entity), Operand(Expression_Ref{view, value}))
					if plan_error != nil { return plan_error }
					if !supported {
						expression_unsupported(checker, view, switch_scope, value, "Switch_Comparison") or_return
						return nil
					}
					append(&comparisons, plan) or_return
				}
			} else {
				expression_condition(checker, view, switch_scope, value) or_return
			}
		}
		clause_scope, clause_error := scope_create(checker.type_checker.resolver.scopes, switch_scope, .Block)
		if clause_error != nil { return binding_resolve_error(clause_error) }
		clause_statements := syntax.node_list(file.ast, case_clause.body)
		expression_predeclare_constants(checker, view, file_id, clause_scope, clause_statements) or_return
		for statement_node in clause_statements {
			expression_statement(checker, view, file_id, clause_scope, statement_node) or_return
		}
		expression_store(checker, view, clause, Expression_Info{scope = clause_scope, state = .Checked})
	}
	switch_plan: Plan_Id
	if tag_entity != 0 {
		switch_plan = Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Switch_Plan{tag = tag_entity, comparisons = comparisons[:]})) or_return
	}
	expression_store(checker, view, node, Expression_Info{scope = scope, plan = switch_plan, state = .Checked})
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
		expression_unsupported(checker, view, scope, statement.cond, "When_Condition") or_return
		return nil
	}
	taken, skipped := statement.body, statement.else_stmt
	if !value { taken, skipped = statement.else_stmt, statement.body }
	if taken != 0 {
		expression_when_body(checker, view, file_id, scope, taken) or_return
		expression_store(checker, view, taken, Expression_Info{scope = scope, state = .Checked})
	}
	if skipped != 0 { expression_store(checker, view, skipped, Expression_Info{scope = scope, state = .Inactive}) }
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

@(private = "package")
expression_ternary_when :: proc(
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
	ternary := syntax.node_payload(file.ast, node, syntax.Ternary_Expr)
	condition := check_expression(checker, view, scope, ternary.cond) or_return
	if condition.state == .Invalid { return expression_poison(scope), nil }
	if condition.mode != .Constant { return expression_failure(checker, view, scope, ternary.cond, .Expected_Boolean_Constant) }
	value, is_bool := constant_pool_get(checker.constants, condition.constant).value.(bool)
	if !is_bool { return expression_failure(checker, view, scope, ternary.cond, .Expected_Boolean_Constant) }
	taken, skipped := ternary.x, ternary.y
	if !value { taken, skipped = ternary.y, ternary.x }
	info = check_expression(checker, view, scope, taken, hint) or_return
	expression_store(checker, view, skipped, Expression_Info{scope = scope, state = .Inactive})
	return info, nil
}

// A block-free `when` body shares the enclosing scope, as in check_when_stmt.
@(private = "package")
expression_when_body :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	if file.ast.nodes[node].kind != .Block_Stmt { return expression_statement(checker, view, file_id, scope, node) }
	statements := syntax.node_list(file.ast, syntax.node_payload(file.ast, node, syntax.Block_Stmt).stmts)
	expression_predeclare_constants(checker, view, file_id, scope, statements) or_return
	for stmt in statements {
		expression_statement(checker, view, file_id, scope, stmt) or_return
	}
	return nil
}

// Official check_scope_decls: constants of a statement list are visible in the whole list and resolve on first use.
@(private = "package")
expression_predeclare_constants :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	statements: []syntax.Node_Index,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	scopes := checker.type_checker.resolver.scopes
	for statement in statements {
		if file.ast.nodes[statement].kind != .Value_Decl { continue }
		declaration := syntax.node_payload(file.ast, statement, syntax.Value_Decl)
		if declaration.is_mutable || declaration.type != 0 { continue }
		names := syntax.node_list(file.ast, declaration.names)
		values := syntax.node_list(file.ast, declaration.values)
		if len(names) == 0 || len(values) != len(names) { continue }
		for name_node, index in names {
			kind := Entity_Kind.Constant
			data: Entity_Data
			if file.ast.nodes[values[index]].kind == .Proc_Group {
				kind = .Procedure_Group
				data = Procedure_Group_Data{}
			}
			constant, create_error := entity_create(
				scopes,
				Entity {
					name = expression_text(file, name_node),
					kind = kind,
					scope = scope,
					package_id = file.package_id,
					declaration = {file_id, name_node},
					state = .Unresolved,
					data = data,
				},
			)
			if create_error != nil { return binding_resolve_error(create_error) }
			previous, insert_error := scope_insert(scopes, scope, constant)
			if insert_error != nil { return binding_resolve_error(insert_error) }
			if previous != 0 {
				expression_unsupported(checker, view, scope, name_node, "Local_Constant_Duplicate") or_return
				return nil
			}
			checker.type_checker.declarations[constant] = Collected_Declaration {
				entity     = constant,
				identifier = {file_id, name_node},
				value      = {file_id, values[index]},
			}
		}
	}
	return nil
}

@(private = "file")
expression_predeclared_constant :: proc(
	checker: ^Expression_Checker,
	file_id: File_Id,
	scope: Scope_Id,
	name_node: syntax.Node_Index,
) -> (
	entity: Entity_Id,
	found: bool,
) {
	file := checker.type_checker.files[file_id]
	entity = scope_lookup_current(checker.type_checker.resolver.scopes, scope, expression_text(file, name_node))
	if entity == 0 { return 0, false }
	record, declared := checker.type_checker.declarations[entity]
	return entity, declared && record.identifier.node == name_node
}

@(private = "package")
expression_local_constant :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	declaration := syntax.node_payload(file.ast, node, syntax.Value_Decl)
	names := syntax.node_list(file.ast, declaration.names)
	values := syntax.node_list(file.ast, declaration.values)
	if len(names) == 0 || len(values) != len(names) {
		expression_unsupported(checker, view, scope, node, "Local_Constant_Declaration") or_return
		return nil
	}
	for name_node, index in names {
		if predeclared, declared := expression_predeclared_constant(checker, file_id, scope, name_node); declared {
			_, resolve_error := resolve_entity(checker.type_checker.resolver, predeclared)
			if resolve_error != nil { return resolve_error }
			continue
		}
		if file.ast.nodes[values[index]].kind == .Proc_Group {
			entity := Entity {
				name       = expression_text(file, name_node),
				kind       = .Procedure_Group,
				scope      = scope,
				package_id = file.package_id,
				state      = .Resolved,
				data       = Procedure_Group_Data{},
			}
			group, create_error := entity_create(checker.type_checker.resolver.scopes, entity)
			if create_error != nil { return binding_resolve_error(create_error) }
			previous, insert_error := scope_insert(checker.type_checker.resolver.scopes, scope, group)
			if insert_error != nil { return binding_resolve_error(insert_error) }
			if previous != 0 {
				expression_unsupported(checker, view, scope, name_node, "Local_Constant_Duplicate") or_return
				return nil
			}
			declaration := Collected_Declaration {
				entity     = group,
				identifier = {file_id, name_node},
				value      = {file_id, values[index]},
			}
			valid, group_error := expression_procedure_group_declaration(checker, checker.type_checker.resolver, group, declaration, scope)
			if group_error != nil { return group_error }
			if !valid { entity_get(checker.type_checker.resolver.scopes, group).state = .Invalid }
			continue
		}
		if file.ast.nodes[values[index]].kind == .Proc_Lit {
			_ = expression_procedure_literal(checker, view, file_id, scope, values[index], name_node) or_return
			continue
		}
		entity := Entity {
			name  = expression_text(file, name_node),
			kind  = .Constant,
			scope = scope,
			state = .Resolved,
		}
		if value_kind := file.ast.nodes[values[index]].kind; .Typeid_Type <= value_kind && value_kind <= .Bit_Field_Type {
			if value_kind == .Distinct_Type {
				entity.kind = .Type_Name
				constant, create_error := entity_create(checker.type_checker.resolver.scopes, entity)
				if create_error != nil { return binding_resolve_error(create_error) }
				nominal := publish_nominal(checker.type_checker, constant, .Named, expression_text(file, name_node)) or_return
				base := type_expression(
					checker.type_checker,
					file_id,
					scope,
					syntax.node_payload(file.ast, values[index], syntax.Distinct_Type).type,
					true,
				) or_return
				if base != types.TYPE_POISON {
					types.complete_nominal(checker.type_checker.store, nominal, types.Type{kind = .Named, name = entity.name, elem = base, is_nominal = true})
				} else {
					entity_get(checker.type_checker.resolver.scopes, constant).state = .Invalid
				}
				previous, insert_error := scope_insert(checker.type_checker.resolver.scopes, scope, constant)
				if insert_error != nil { return binding_resolve_error(insert_error) }
				if previous != 0 {
					expression_unsupported(checker, view, scope, name_node, "Local_Constant_Duplicate") or_return
					return nil
				}
				continue
			}
			target := type_expression(checker.type_checker, file_id, scope, values[index], true) or_return
			if target == types.TYPE_POISON { return nil }
			entity.kind, entity.type = .Type_Name, target
		} else {
			hint := types.TYPE_NONE
			if declaration.type != 0 {
				hint = type_expression(checker.type_checker, file_id, scope, declaration.type, true) or_return
				if hint == types.TYPE_POISON { return nil }
			}
			value := check_expression(checker, view, scope, values[index], hint) or_return
			if value.state == .Invalid { return nil }
			if value.mode == .Builtin {
				entity.kind = .Builtin
				entity.data = entity_get(checker.type_checker.resolver.scopes, value.entity).data
			} else {
				if value.mode != .Constant {
					expression_unsupported(checker, view, scope, values[index], "Local_Constant_Value") or_return
					return nil
				}
				entity.type, entity.constant = value.type, value.constant
			}
		}
		constant, create_error := entity_create(checker.type_checker.resolver.scopes, entity)
		if create_error != nil { return binding_resolve_error(create_error) }
		previous, insert_error := scope_insert(checker.type_checker.resolver.scopes, scope, constant)
		if insert_error != nil { return binding_resolve_error(insert_error) }
		if previous != 0 {
			expression_unsupported(checker, view, scope, name_node, "Local_Constant_Duplicate") or_return
			return nil
		}
	}
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
	case .Fallthrough:
		exit_kind = .Fallthrough
	case:
		expression_unsupported(checker, view, scope, node, "Branch_Kind") or_return
		return nil
	}
	label := expression_label(file, statement.label)
	for index := len(checker.control) - 1; index >= 0; index -= 1 {
		frame := checker.control[index]
		if label == "" && frame.is_barrier { break }
		// fallthrough is only valid as the last statement of a non-last
		// case body in a non-type switch; the control frame here is the
		// switch itself, so accept it there.
		if label != "" && frame.label != label { continue }
		if label == "" && !frame.is_loop && (exit_kind == .Continue || !frame.is_switch) { continue }
		if exit_kind == .Fallthrough && !frame.is_switch { continue }
		if exit_kind == .Fallthrough && file.ast.nodes[frame.node].kind == .Type_Switch_Stmt {
			expression_unsupported(checker, view, scope, node, "Fallthrough_Type_Switch") or_return
			return nil
		}
		if exit_kind == .Continue && !frame.is_loop { break }
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Exit_Plan{kind = exit_kind, target = Node_Ref{file_id, frame.node}})) or_return
		expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
		return nil
	}
	expression_unsupported(checker, view, scope, node, "Branch_Target") or_return
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

@(private = "package")
expression_label :: proc(file: ^File, label: syntax.Node_Index) -> string {
	if label == 0 { return "" }
	return expression_text(file, label)
}

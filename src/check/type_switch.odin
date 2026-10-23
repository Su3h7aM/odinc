package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_type_switch :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	statement := syntax.node_payload(file.ast, node, syntax.Type_Switch_Stmt)
	switch_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block)
	if scope_error != nil { return binding_resolve_error(scope_error) }
	assignment := syntax.node_payload(file.ast, statement.tag, syntax.Assign_Stmt)
	lhs := syntax.node_list(file.ast, assignment.lhs)
	rhs := syntax.node_list(file.ast, assignment.rhs)
	if len(lhs) != 1 || len(rhs) != 1 {
		expression_unsupported(checker, view, scope, node, "Type_Switch_Form") or_return
		return nil
	}
	name_node := lhs[0]
	is_reference := false
	if file.ast.nodes[name_node].kind == .Unary_Expr {
		unary := syntax.node_payload(file.ast, name_node, syntax.Unary_Expr)
		if unary.op.kind != .And {
			expression_unsupported(checker, view, scope, name_node, "Type_Switch_Form") or_return
			return nil
		}
		is_reference = true
		name_node = unary.expr
	}
	if file.ast.nodes[name_node].kind != .Ident {
		expression_unsupported(checker, view, scope, name_node, "Type_Switch_Form") or_return
		return nil
	}

	subject := check_expression(checker, view, switch_scope, rhs[0]) or_return
	if subject.state == .Invalid { return nil }
	store := checker.type_checker.store
	subject_type := subject.type
	subject_is_pointer := types.get(store, types.resolve_named(store, subject_type)).kind == .Pointer
	if subject_is_pointer { subject_type = types.get(store, types.resolve_named(store, subject_type)).elem }
	descriptor := types.get(store, types.resolve_named(store, subject_type))^
	if subject.mode == .Type || (descriptor.kind != .Union && descriptor.kind != .Any) {
		expression_failure(checker, view, scope, rhs[0], .Invalid_Operand) or_return
		return nil
	}
	if statement.partial && descriptor.kind != .Union {
		expression_failure(checker, view, scope, node, .Invalid_Operand) or_return
		return nil
	}
	if is_reference && descriptor.kind == .Union && subject.mode != .Variable && !subject_is_pointer {
		expression_failure(checker, view, scope, name_node, .Invalid_Operand) or_return
		return nil
	}

	name := expression_text(file, name_node)
	nilable := conversion_nilable(descriptor)
	variants := descriptor.variants
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	clauses := make([dynamic]Type_Switch_Clause, allocator) or_return
	seen := make([dynamic]types.Type_Id, allocator) or_return
	append(&checker.control, Control_Frame{node = node, label = expression_label(file, statement.label), is_switch = true}) or_return
	defer pop(&checker.control)
	default_seen := false
	nil_seen := false
	for clause_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, statement.body, syntax.Block_Stmt).stmts) {
		case_clause := syntax.node_payload(file.ast, clause_node, syntax.Case_Clause)
		values := syntax.node_list(file.ast, case_clause.list)
		if len(values) == 0 {
			if default_seen {
				expression_failure(checker, view, switch_scope, clause_node, .Invalid_Operand) or_return
				return nil
			}
			default_seen = true
		}
		case_variants := make([dynamic]types.Type_Id, allocator) or_return
		for value in values {
			variant: Expression_Info
			if file.ast.nodes[value].kind >= .Typeid_Type && file.ast.nodes[value].kind <= .Bit_Field_Type {
				variant_type := type_expression(checker.type_checker, file_id, switch_scope, value, true) or_return
				variant = Expression_Info {
					type  = variant_type,
					mode  = .Type,
					scope = switch_scope,
					state = .Checked,
				}
			} else {
				variant = check_expression(checker, view, switch_scope, value) or_return
			}
			if variant.state == .Invalid { return nil }
			if variant.type == types.TYPE_UNTYPED_NIL {
				if !nilable || nil_seen {
					expression_failure(checker, view, switch_scope, value, .Invalid_Operand) or_return
					return nil
				}
				nil_seen = true
				append(&case_variants, types.TYPE_UNTYPED_NIL) or_return
				continue
			}
			if variant.mode != .Type ||
			   (descriptor.kind == .Union && !type_list_contains(store, variants, variant.type)) ||
			   type_list_contains(store, seen[:], variant.type, true) {
				expression_failure(checker, view, switch_scope, value, .Invalid_Operand) or_return
				return nil
			}
			append(&seen, variant.type) or_return
			if descriptor.kind == .Any { expression_record_type_info(checker, variant.type) or_return }
			append(&case_variants, variant.type) or_return
		}
		clause_type := subject_type
		if len(case_variants) == 1 && case_variants[0] != types.TYPE_UNTYPED_NIL { clause_type = case_variants[0] }
		clause_scope, clause_scope_error := scope_create(checker.type_checker.resolver.scopes, switch_scope, .Block)
		if clause_scope_error != nil { return binding_resolve_error(clause_scope_error) }
		clause_entity: Entity_Id
		if name != "_" {
			created, create_error := entity_create(
				checker.type_checker.resolver.scopes,
				Entity {
					name = name,
					kind = .Variable,
					scope = clause_scope,
					declaration = {file_id, name_node},
					state = .Resolved,
					flags = {.Used},
					type = clause_type,
					data = Variable_Data{storage = .Local},
				},
			)
			if create_error != nil { return binding_resolve_error(create_error) }
			_, insert_error := scope_insert(checker.type_checker.resolver.scopes, clause_scope, created)
			if insert_error != nil { return binding_resolve_error(insert_error) }
			clause_entity = created
		}
		for statement_node in syntax.node_list(file.ast, case_clause.body) {
			expression_statement(checker, view, file_id, clause_scope, statement_node) or_return
		}
		expression_store(checker, view, clause_node, Expression_Info{scope = clause_scope, state = .Checked})
		append(&clauses, Type_Switch_Clause{entity = clause_entity, variants = case_variants[:]}) or_return
	}
	if !statement.partial && descriptor.kind == .Union {
		for variant in variants {
			if !type_list_contains(store, seen[:], variant, true) {
				expression_failure(checker, view, scope, node, .Invalid_Operand) or_return
				return nil
			}
		}
	}
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(Type_Switch_Plan{subject = Operand(Expression_Ref{view, rhs[0]}), subject_type = subject_type, reference = is_reference, clauses = clauses[:]}),
	) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, plan = plan, state = .Checked})
	return nil
}

@(private = "package")
type_list_contains :: proc(store: ^types.Store, list: []types.Type_Id, type: types.Type_Id, unique_tuples: bool = false) -> bool {
	for candidate in list {
		if unique_tuples {
			if types.are_identical_unique_tuples(store, candidate, type) { return true }
		} else if types.are_identical(store, candidate, type) { return true }
	}
	return false
}

package check

import "base:runtime"
import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_conversion_plan :: proc(checker: ^Expression_Checker, plan: Plan_Id) -> Plan_Id {
	if plan == 0 { return 0 }
	if _, is_conversion := checker.plans[plan].(Conversion_Plan); is_conversion { return plan }
	return 0
}

@(private = "file")
expression_assignment_operator :: proc(kind: syntax.Token_Kind) -> bool {
	#partial switch kind {
	case .Eq, .Add_Eq, .Sub_Eq, .Mul_Eq, .Quo_Eq, .Mod_Eq, .Mod_Mod_Eq, .And_Eq, .Or_Eq, .Xor_Eq, .And_Not_Eq, .Shl_Eq, .Shr_Eq:
		return true
	}
	return false
}

binding_resolve_error :: proc(err: Binding_Error) -> Resolve_Error {
	switch failure in err {
	case Scope_Error:
		return failure
	case runtime.Allocator_Error:
		return failure
	}
	return nil
}

// Fills the signature of a procedure, then checks its body. Parameters and results need the S1 call model and remain unsupported.
@(private = "package")
expression_procedure_declaration :: proc(
	checker: ^Expression_Checker,
	resolver: ^Resolver,
	id: Entity_Id,
	declaration: Collected_Declaration,
	scope: Scope_Id,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	view := expression_file_view(checker, declaration.type.file) or_return
	if declaration.type.node == 0 {
		expression_failure(checker, view, scope, declaration.identifier.node, .Unsupported) or_return
		return false, nil
	}
	signature := type_expression(checker.type_checker, declaration.type.file, scope, declaration.type.node, true) or_return
	if signature == types.TYPE_POISON { return false, nil }
	descriptor := types.get(checker.type_checker.store, signature)
	entity := entity_get(resolver.scopes, id)
	procedure := &entity.data.(Procedure_Data)
	procedure.signature = signature
	procedure.convention = descriptor.convention
	entity.type = signature
	return expression_procedure_body(checker, resolver, id, declaration.type)
}

@(private = "file")
expression_procedure_body :: proc(checker: ^Expression_Checker, resolver: ^Resolver, id: Entity_Id, signature: Node_Ref) -> (valid: bool, err: Resolve_Error) {
	body := entity_get(resolver.scopes, id).data.(Procedure_Data).body
	if body.node == 0 { return true, nil }
	view := expression_file_view(checker, body.file) or_return
	procedure_scope, scope_error := scope_create(resolver.scopes, entity_get(resolver.scopes, id).scope, .Procedure, id)
	if scope_error != nil { return false, binding_resolve_error(scope_error) }
	procedure := &entity_get(resolver.scopes, id).data.(Procedure_Data)
	procedure.body_state = .Checking
	outer_results := checker.results
	defer checker.results = outer_results
	expression_signature_bindings(checker, resolver, id, signature, procedure_scope) or_return
	expression_block(checker, view, body.file, procedure_scope, body.node) or_return
	procedure = &entity_get(resolver.scopes, id).data.(Procedure_Data)
	procedure.body_state = .Complete
	return true, nil
}

@(private = "file")
expression_signature_bindings :: proc(
	checker: ^Expression_Checker,
	resolver: ^Resolver,
	id: Entity_Id,
	signature: Node_Ref,
	scope: Scope_Id,
) -> (
	err: Resolve_Error,
) {
	file := checker.type_checker.files[signature.file]
	view := expression_file_view(checker, signature.file) or_return
	proc_type := syntax.node_payload(file.ast, signature.node, syntax.Proc_Type)
	descriptor := types.get(checker.type_checker.store, entity_get(resolver.scopes, id).type)
	parameter_types := descriptor.params
	result_types := descriptor.results
	parameters: [dynamic]Entity_Id
	parameters.allocator = mem.dynamic_arena_allocator(&checker.arena)
	if proc_type.params != 0 {
		for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, proc_type.params, syntax.Field_List).list) {
			field := syntax.node_payload(file.ast, field_node, syntax.Field)
			if field.default_value != 0 || field.names.count == 0 {
				expression_failure(checker, view, scope, field_node, .Unsupported) or_return
				return nil
			}
			for name_node in syntax.node_list(file.ast, field.names) {
				if len(parameters) >= len(parameter_types) { return nil }
				parameter, create_error := entity_create(
					resolver.scopes,
					Entity {
						name = expression_text(file, name_node),
						kind = .Variable,
						scope = scope,
						state = .Resolved,
						type = parameter_types[len(parameters)],
						data = Variable_Data{storage = .Local},
					},
				)
				if create_error != nil { return binding_resolve_error(create_error) }
				previous, insert_error := scope_insert(resolver.scopes, scope, parameter)
				if insert_error != nil { return binding_resolve_error(insert_error) }
				if previous != 0 {
					expression_failure(checker, view, scope, name_node, .Unsupported) or_return
					return nil
				}
				expression_store(
					checker,
					view,
					name_node,
					Expression_Info{type = parameter_types[len(parameters)], mode = .Variable, entity = parameter, scope = scope, state = .Checked},
				)
				append(&parameters, parameter) or_return
			}
		}
	}
	if proc_type.results != 0 {
		for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, proc_type.results, syntax.Field_List).list) {
			if syntax.node_payload(file.ast, field_node, syntax.Field).names.count != 0 {
				expression_failure(checker, view, scope, field_node, .Unsupported) or_return
				return nil
			}
		}
	}
	checker.results = result_types
	procedure := &entity_get(resolver.scopes, id).data.(Procedure_Data)
	procedure.parameters = parameters[:]
	return nil
}

expression_block :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	block := syntax.node_payload(file.ast, node, syntax.Block_Stmt)
	block_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block)
	if scope_error != nil { return binding_resolve_error(scope_error) }
	for statement in syntax.node_list(file.ast, block.stmts) {
		expression_statement(checker, view, file_id, block_scope, statement) or_return
	}
	return nil
}

expression_statement :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	#partial switch file.ast.nodes[node].kind {
	case .Empty_Stmt:
		return nil
	case .Value_Decl:
		return expression_local_declaration(checker, view, file_id, scope, node)
	case .Block_Stmt:
		return expression_labeled_block(checker, view, file_id, scope, node)
	case .If_Stmt:
		return expression_if(checker, view, file_id, scope, node)
	case .For_Stmt:
		return expression_for(checker, view, file_id, scope, node)
	case .Switch_Stmt:
		return expression_switch(checker, view, file_id, scope, node)
	case .When_Stmt:
		return expression_when(checker, view, file_id, scope, node)
	case .Branch_Stmt:
		return expression_branch(checker, view, file_id, scope, node)
	case .Assign_Stmt:
		return expression_assignment(checker, view, file_id, scope, node)
	case .Return_Stmt:
		return expression_return(checker, view, file_id, scope, node)
	case .Range_Stmt:
		return expression_range(checker, view, file_id, scope, node)
	case .Expr_Stmt:
		_ = check_expression(checker, view, scope, syntax.node_payload(file.ast, node, syntax.Expr_Stmt).expr) or_return
		return nil
	case:
		expression_failure(checker, view, scope, node, .Unsupported) or_return
		return nil
	}
}

@(private = "file")
expression_assignment :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	assignment := syntax.node_payload(file.ast, node, syntax.Assign_Stmt)
	left := syntax.node_list(file.ast, assignment.lhs)
	right := syntax.node_list(file.ast, assignment.rhs)
	if !expression_assignment_operator(assignment.op.kind) || len(left) != 1 || len(right) != 1 {
		expression_failure(checker, view, scope, node, .Unsupported) or_return
		return nil
	}
	destination := check_expression(checker, view, scope, left[0]) or_return
	if destination.state == .Invalid { return nil }
	if destination.mode != .Variable {
		expression_failure(checker, view, scope, left[0], .Unsupported) or_return
		return nil
	}
	value := check_expression(checker, view, scope, right[0], destination.type) or_return
	if value.state == .Invalid { return nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	destinations := make([]Operand, 1, allocator) or_return
	values := make([]Operand, 1, allocator) or_return
	conversions := make([]Plan_Id, 1, allocator) or_return
	destinations[0] = Operand(Expression_Ref{view, left[0]})
	values[0] = Operand(Expression_Ref{view, right[0]})
	conversions[0] = expression_conversion_plan(checker, value.plan)
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Assignment_Plan{destinations = destinations, values = values, conversions = conversions})) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
	return nil
}

@(private = "file")
expression_return :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	values := syntax.node_list(file.ast, syntax.node_payload(file.ast, node, syntax.Return_Stmt).results)
	if len(values) != len(checker.results) {
		expression_failure(checker, view, scope, node, .Unsupported) or_return
		return nil
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, len(values), allocator) or_return
	for value, index in values {
		info := check_expression(checker, view, scope, value, checker.results[index]) or_return
		if info.state == .Invalid { return nil }
		operands[index] = Operand(Expression_Ref{view, value})
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Exit_Plan{kind = .Return, values = operands})) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
	return nil
}

@(private = "file")
expression_range :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	loop := syntax.node_payload(file.ast, node, syntax.Range_Stmt)
	variables := syntax.node_list(file.ast, loop.vals)
	if loop.reverse || len(variables) != 1 || file.ast.nodes[loop.expr].kind != .Binary_Expr {
		expression_failure(checker, view, scope, node, .Unsupported) or_return
		return nil
	}
	interval := syntax.node_payload(file.ast, loop.expr, syntax.Binary_Expr)
	if interval.op.kind != .Range_Half {
		expression_failure(checker, view, scope, loop.expr, .Unsupported) or_return
		return nil
	}
	low := check_expression(checker, view, scope, interval.left, checker.default_integer) or_return
	if low.state == .Invalid { return nil }
	high := check_expression(checker, view, scope, interval.right, low.type) or_return
	if high.state == .Invalid { return nil }
	if !conversion_integer(types.get(checker.type_checker.store, low.type).kind) {
		expression_failure(checker, view, scope, loop.expr, .Unsupported) or_return
		return nil
	}
	scopes := checker.type_checker.resolver.scopes
	range_scope, scope_error := scope_create(scopes, scope, .Block)
	if scope_error != nil { return binding_resolve_error(scope_error) }
	variable, create_error := entity_create(
		scopes,
		Entity {
			name = expression_text(file, variables[0]),
			kind = .Variable,
			scope = range_scope,
			state = .Resolved,
			type = low.type,
			data = Variable_Data{storage = .Local},
		},
	)
	if create_error != nil { return binding_resolve_error(create_error) }
	_, insert_error := scope_insert(scopes, range_scope, variable)
	if insert_error != nil { return binding_resolve_error(insert_error) }
	expression_store(checker, view, variables[0], Expression_Info{type = low.type, mode = .Variable, entity = variable, scope = range_scope, state = .Checked})
	unchecked := .No_Bounds_Check in file.ast.nodes[node].flags
	if unchecked { checker.unchecked_depth += 1 }
	body_error := expression_statement(checker, view, file_id, range_scope, loop.body)
	if unchecked { checker.unchecked_depth -= 1 }
	if body_error != nil { return body_error }
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked})
	return nil
}

@(private = "file")
expression_local_declaration :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	declaration := syntax.node_payload(file.ast, node, syntax.Value_Decl)
	names := syntax.node_list(file.ast, declaration.names)
	values := syntax.node_list(file.ast, declaration.values)
	if !declaration.is_mutable || (len(values) != 0 && len(values) != len(names)) || (declaration.type == 0 && len(values) == 0) {
		expression_failure(checker, view, scope, node, .Unsupported) or_return
		return nil
	}
	target: types.Type_Id
	if declaration.type != 0 {
		target = type_expression(checker.type_checker, file_id, scope, declaration.type, true) or_return
		if target == types.TYPE_POISON { return nil }
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	variable_types := make([]types.Type_Id, len(names), allocator) or_return
	for index in 0 ..< len(values) {
		value := check_expression(checker, view, scope, values[index], target) or_return
		if value.state == .Invalid { return nil }
		variable_types[index] = target
		if target != 0 { continue }
		#partial switch types.get(checker.type_checker.store, value.type).kind {
		case .Untyped_Integer:
			variable_types[index] = checker.default_integer
		case .Untyped_Bool:
			variable_types[index] = checker.boolean
		case:
			variable_types[index] = value.type
		}
		if variable_types[index] != value.type {
			_ = check_expression(checker, view, scope, values[index], variable_types[index]) or_return
		}
	}
	if len(values) == 0 {
		for index in 0 ..< len(names) { variable_types[index] = target }
	}
	scopes := checker.type_checker.resolver.scopes
	for name_node, index in names {
		id, create_error := entity_create(
			scopes,
			Entity {
				name = expression_text(file, name_node),
				kind = .Variable,
				scope = scope,
				state = .Resolved,
				type = variable_types[index],
				data = Variable_Data{storage = .Local},
			},
		)
		if create_error != nil { return binding_resolve_error(create_error) }
		previous, insert_error := scope_insert(scopes, scope, id)
		if insert_error != nil { return Scope_Error.Invalid_Entity }
		if previous != 0 {
			expression_failure(checker, view, scope, name_node, .Unsupported) or_return
			return nil
		}
		expression_store(
			checker,
			view,
			name_node,
			Expression_Info{type = variable_types[index], mode = .Variable, entity = id, scope = scope, state = .Checked},
		)
	}
	return nil
}

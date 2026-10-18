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
		expression_unsupported(checker, view, scope, declaration.identifier.node, "Procedure_Declaration") or_return
		return false, nil
	}
	if syntax.node_payload(checker.type_checker.files[declaration.type.file].ast, declaration.type.node, syntax.Proc_Type).generic {
		procedure := &entity_get(resolver.scopes, id).data.(Procedure_Data)
		procedure.generic = true
		return true, nil
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

@(private = "package")
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
	outer_named_results := checker.named_results
	defer checker.named_results = outer_named_results
	outer_control := checker.control
	checker.control = make([dynamic]Control_Frame, outer_control.allocator) or_return
	outer_defer_depth := checker.defer_depth
	outer_unchecked_depth := checker.unchecked_depth
	checker.defer_depth, checker.unchecked_depth = 0, 0
	defer {
		delete(checker.control)
		checker.control = outer_control
		checker.defer_depth = outer_defer_depth
		checker.unchecked_depth = outer_unchecked_depth
	}
	expression_signature_bindings(checker, resolver, id, signature, procedure_scope) or_return
	diagnostics_before := len(checker.diagnostics)
	defers_first := len(checker.defers)
	expression_block(checker, view, body.file, procedure_scope, body.node) or_return
	procedure = &entity_get(resolver.scopes, id).data.(Procedure_Data)
	procedure.defers = expression_take_defers(checker, defers_first) or_return
	procedure.body_state = .Invalid if expression_diagnostics_within(checker, diagnostics_before, body) else .Complete
	return true, nil
}

// A body with a reported error keeps unchecked statements, so it must not be published or lowered.
@(private = "file")
expression_diagnostics_within :: proc(checker: ^Expression_Checker, first: int, body: Node_Ref) -> bool {
	span := checker.type_checker.files[body.file].ast.nodes[body.node]
	for diagnostic in checker.diagnostics[first:] {
		source := diagnostic.source
		if source.file == body.file && source.start >= span.start && source.end <= span.end { return true }
	}
	return false
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
	defaults: [dynamic]Default_Argument
	defaults.allocator = mem.dynamic_arena_allocator(&checker.arena)
	declaration_scope := entity_get(resolver.scopes, id).scope
	named_results: []Entity_Id
	if proc_type.params != 0 {
		for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, proc_type.params, syntax.Field_List).list) {
			field := syntax.node_payload(file.ast, field_node, syntax.Field)
			if is_type_param_field(file, field) { continue }
			if field.names.count == 0 {
				expression_unsupported(checker, view, scope, field_node, "Parameter_Name") or_return
				return nil
			}
			for name_node in syntax.node_list(file.ast, field.names) {
				if len(parameters) >= len(parameter_types) { return nil }
				default_argument: Default_Argument
				if field.default_value != 0 {
					default_argument = expression_default_argument(
						checker,
						view,
						declaration_scope,
						field.default_value,
						parameter_types[len(parameters)],
					) or_return
				}
				append(&defaults, default_argument) or_return
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
					expression_unsupported(checker, view, scope, name_node, "Parameter_Duplicate") or_return
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
		bindings, bound, bind_error := expression_result_bindings(checker, resolver, view, signature.file, scope, proc_type.results, result_types)
		if bind_error != nil { return bind_error }
		if !bound { return nil }
		named_results = bindings
	}
	checker.results = result_types
	checker.named_results = named_results
	procedure := &entity_get(resolver.scopes, id).data.(Procedure_Data)
	procedure.parameters = parameters[:]
	procedure.defaults = defaults[:]
	procedure.results = named_results
	return nil
}

@(private = "file")
expression_default_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	type: types.Type_Id,
) -> (
	argument: Default_Argument,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	if file.ast.nodes[node].kind == .Basic_Directive {
		switch expression_text(file, node) {
		case "#caller_location":
			return Default_Argument{caller_location = true}, nil
		case "#caller_expression":
			return Default_Argument{caller_expression = true}, nil
		}
		expression_unsupported(checker, view, scope, node, "Default_Directive") or_return
		return {}, nil
	}
	if file.ast.nodes[node].kind == .Call_Expr {
		call := syntax.node_payload(file.ast, node, syntax.Call_Expr)
		if file.ast.nodes[call.expr].kind == .Basic_Directive && expression_text(file, call.expr) == "#caller_expression" {
			targets := syntax.node_list(file.ast, call.args)
			if len(targets) == 1 && file.ast.nodes[targets[0]].kind == .Ident {
				return Default_Argument{caller_expression = true, caller_expression_target = expression_text(file, targets[0])}, nil
			}
			expression_unsupported(checker, view, scope, node, "Caller_Expression_Arguments") or_return
			return {}, nil
		}
	}
	info := check_expression(checker, view, scope, node, type) or_return
	if info.state == .Invalid { return {}, nil }
	if info.constant != 0 { return Default_Argument{value = Operand(info.constant)}, nil }
	if expression_conversion_plan(checker, info.plan) != 0 {
		expression_unsupported(checker, view, scope, node, "Default_Conversion") or_return
		return {}, nil
	}
	return Default_Argument{value = Operand(Expression_Ref{view, node})}, nil
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
	// As check_stmt in the official compiler: a statement's #no_bounds_check or #bounds_check applies to the whole statement.
	unchecked_depth := checker.unchecked_depth
	defer checker.unchecked_depth = unchecked_depth
	if .No_Bounds_Check in file.ast.nodes[node].flags {
		checker.unchecked_depth += 1
	} else if .Bounds_Check in file.ast.nodes[node].flags {
		checker.unchecked_depth = 0
	}
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
	case .Defer_Stmt:
		return expression_defer(checker, view, file_id, scope, node)
	case .Range_Stmt:
		return expression_range(checker, view, file_id, scope, node)
	case .Expr_Stmt:
		expression := syntax.node_payload(file.ast, node, syntax.Expr_Stmt).expr
		info := check_expression(checker, view, scope, expression) or_return
		classified_expression := expression
		for file.ast.nodes[classified_expression].kind == .Paren_Expr {
			classified_expression = syntax.node_payload(file.ast, classified_expression, syntax.Paren_Expr).expr
		}
		if info.state != .Invalid && file.ast.nodes[classified_expression].kind == .Or_Return_Expr && info.mode != .No_Value {
			expression_unsupported(checker, view, scope, expression, "Statement_Or_Return_Value") or_return
		}
		return nil
	case:
		expression_unsupported(checker, view, scope, node, "Statement_Kind") or_return
		return nil
	}
}

@(private = "file")
expression_assignment :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	assignment := syntax.node_payload(file.ast, node, syntax.Assign_Stmt)
	left := syntax.node_list(file.ast, assignment.lhs)
	right := syntax.node_list(file.ast, assignment.rhs)
	if assignment.op.kind == .Eq && (len(left) != 1 || len(right) != 1) {
		return expression_multiple_assignment(checker, view, file_id, scope, node, left, right)
	}
	if !expression_assignment_operator(assignment.op.kind) || len(left) != 1 || len(right) != 1 {
		expression_unsupported(checker, view, scope, node, "Assign_Arity") or_return
		return nil
	}
	if assignment.op.kind == .Eq && expression_text(file, left[0]) == "_" {
		return expression_blank_assignment(checker, view, scope, node, right[0])
	}
	destination := check_expression(checker, view, scope, left[0]) or_return
	if destination.state == .Invalid { return nil }
	if destination.mode != .Variable && destination.mode != .Context {
		expression_unsupported(checker, view, scope, left[0], "Assign_Destination_Mode") or_return
		return nil
	}
	if assigns_named_result_in_defer(checker, destination, assignment.op.kind) {
		expression_unsupported(checker, view, scope, left[0], "Assign_Deferred_Result") or_return
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

// `_ = value` evaluates value with its default type and discards it.
@(private = "file")
expression_blank_assignment :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	value_node: syntax.Node_Index,
) -> Resolve_Error {
	store := checker.type_checker.store
	value := check_expression(checker, view, scope, value_node) or_return
	if value.state == .Invalid { return nil }
	if conversion_untyped(types.get(store, value.type).kind) {
		value = check_expression(checker, view, scope, value_node, types.default_type_of_untyped(store, value.type)) or_return
		if value.state == .Invalid { return nil }
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	destinations := make([]Operand, 1, allocator) or_return
	values := make([]Operand, 1, allocator) or_return
	conversions := make([]Plan_Id, 1, allocator) or_return
	destinations[0] = Operand(Entity_Id(0))
	values[0] = Operand(Expression_Ref{view, value_node})
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Assignment_Plan{destinations = destinations, values = values, conversions = conversions})) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
	return nil
}

@(private = "file")
expression_return :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	if checker.defer_depth > 0 {
		expression_unsupported(checker, view, scope, node, "Return_In_Defer") or_return
		return nil
	}
	file := checker.type_checker.files[file_id]
	values := syntax.node_list(file.ast, syntax.node_payload(file.ast, node, syntax.Return_Stmt).results)
	if len(values) != len(checker.results) && (len(values) != 0 || len(checker.named_results) == 0) {
		expression_unsupported(checker, view, scope, node, "Return_Arity") or_return
		return nil
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, len(values), allocator) or_return
	conversions := make([]Plan_Id, len(values), allocator) or_return
	for value, index in values {
		info := check_expression(checker, view, scope, value, checker.results[index]) or_return
		if info.state == .Invalid { return nil }
		conversions[index] = expression_boxing_plan(checker, info.plan)
		operands[index] = Operand(Expression_Ref{view, value})
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Exit_Plan{kind = .Return, values = operands, conversions = conversions})) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
	return nil
}

@(private = "file")
expression_range :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	loop := syntax.node_payload(file.ast, node, syntax.Range_Stmt)
	variables := syntax.node_list(file.ast, loop.vals)
	if loop.reverse || len(variables) != 1 || file.ast.nodes[loop.expr].kind != .Binary_Expr {
		expression_unsupported(checker, view, scope, node, "Range_Form") or_return
		return nil
	}
	interval := syntax.node_payload(file.ast, loop.expr, syntax.Binary_Expr)
	if interval.op.kind != .Range_Half {
		expression_unsupported(checker, view, scope, loop.expr, "Range_Operator") or_return
		return nil
	}
	low := check_expression(checker, view, scope, interval.left) or_return
	if low.state == .Invalid { return nil }
	high := check_expression(checker, view, scope, interval.right) or_return
	if high.state == .Invalid { return nil }
	store := checker.type_checker.store
	range_type := low.type
	if types.is_untyped(store, range_type) { range_type = high.type }
	if types.is_untyped(store, range_type) { range_type = checker.default_integer }
	low = check_expression(checker, view, scope, interval.left, range_type) or_return
	high = check_expression(checker, view, scope, interval.right, range_type) or_return
	if low.state == .Invalid || high.state == .Invalid { return nil }
	if !conversion_integer(types.get(checker.type_checker.store, low.type).kind) {
		expression_unsupported(checker, view, scope, loop.expr, "Range_Type") or_return
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
	body_error := expression_statement(checker, view, file_id, range_scope, loop.body)
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
	multi := len(values) == 1 && len(names) > 1
	if !declaration.is_mutable { return expression_local_constant(checker, view, file_id, scope, node) }
	if (len(values) != 0 && len(values) != len(names) && !multi) || (declaration.type == 0 && len(values) == 0) {
		expression_unsupported(checker, view, scope, node, "Local_Declaration_Arity") or_return
		return nil
	}
	target: types.Type_Id
	if declaration.type != 0 {
		target = type_expression(checker.type_checker, file_id, scope, declaration.type, true) or_return
		if target == types.TYPE_POISON { return nil }
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	variable_types := make([]types.Type_Id, len(names), allocator) or_return
	conversions := make([]Plan_Id, len(values), allocator) or_return
	if multi {
		value := check_expression(checker, view, scope, values[0]) or_return
		if value.state == .Invalid { return nil }
		results: []types.Type_Id
		is_call := false
		if value.plan != 0 {
			#partial switch plan in checker.plans[value.plan] {
			case Call_Plan:
				results, is_call = plan.results, true
			case Builtin_Plan:
				results, is_call = plan.results, true
			}
		}
		if !is_call || target != 0 || len(results) != len(names) {
			expression_unsupported(checker, view, scope, values[0], "Local_Declaration_Results") or_return
			return nil
		}
		for result, index in results { variable_types[index] = result }
	}
	initializes := make([]bool, len(values), allocator) or_return
	for index in 0 ..< len(values) {
		if multi { break }
		if file.ast.nodes[values[index]].kind == .Undef {
			if target == 0 {
				expression_unsupported(checker, view, scope, values[index], "Local_Undef_Type") or_return
				return nil
			}
			variable_types[index] = target
			continue
		}
		initializes[index] = true
		value := check_expression(checker, view, scope, values[index], target) or_return
		if value.state == .Invalid { return nil }
		conversions[index] = expression_boxing_plan(checker, value.plan)
		if value.mode == .No_Value {
			expression_unsupported(checker, view, scope, values[index], "Local_No_Value") or_return
			return nil
		}
		variable_types[index] = target
		if target != 0 { continue }
		#partial switch types.get(checker.type_checker.store, value.type).kind {
		case .Untyped_Integer:
			variable_types[index] = checker.default_integer
		case .Untyped_Bool:
			variable_types[index] = checker.boolean
		case .Untyped_Float:
			variable_types[index] = types.default_type_of_untyped(checker.type_checker.store, value.type)
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
	needs_plan := expression_any_boxed(conversions)
	for initializes_value in initializes {
		if !initializes_value { needs_plan = true; break }
	}
	if needs_plan {
		destinations := make([]Operand, len(values), allocator) or_return
		sources := make([]Operand, len(values), allocator) or_return
		for value, index in values {
			destinations[index] = Operand(Entity_Id(0))
			sources[index] = Operand(Expression_Ref{view, value})
		}
		plan := Plan_Id(len(checker.plans))
		append(
			&checker.plans,
			Plan(Assignment_Plan{destinations = destinations, values = sources, conversions = conversions, initializes = initializes}),
		) or_return
		expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
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
			expression_unsupported(checker, view, scope, name_node, "Local_Duplicate") or_return
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

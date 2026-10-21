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
	case .Eq, .Add_Eq, .Sub_Eq, .Mul_Eq, .Quo_Eq, .Mod_Eq, .Mod_Mod_Eq, .And_Eq, .Or_Eq, .Xor_Eq, .And_Not_Eq, .Shl_Eq, .Shr_Eq, .Cmp_And_Eq, .Cmp_Or_Eq:
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
		return expression_generic_default_validation(checker, id, declaration, scope)
	}
	signature := type_expression(checker.type_checker, declaration.type.file, scope, declaration.type.node, true) or_return
	if signature == types.TYPE_POISON { return false, nil }
	descriptor := types.get(checker.type_checker.store, signature)
	entity := entity_get(resolver.scopes, id)
	procedure := &entity.data.(Procedure_Data)
	procedure.signature = signature
	procedure.convention = descriptor.convention
	procedure.variadic_index = procedure_variadic_index(checker.type_checker.files[declaration.type.file], declaration.type.node)
	entity.type = signature
	if entity.data.(Procedure_Data).body.node == 0 {
		return expression_bodyless_signature_bindings(checker, resolver, id, declaration.type)
	}
	_, append_err := append(&resolver.pending_bodies, id)
	return true, append_err
}

@(private = "package")
expression_procedure_body :: proc(checker: ^Expression_Checker, resolver: ^Resolver, id: Entity_Id, signature: Node_Ref) -> (valid: bool, err: Resolve_Error) {
	body := entity_get(resolver.scopes, id).data.(Procedure_Data).body
	if body.node == 0 { return expression_bodyless_signature_bindings(checker, resolver, id, signature) }
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
	if !(expression_procedure_where(checker, view, procedure_scope, entity_get(resolver.scopes, id).data.(Procedure_Data).where_clauses) or_return) {
		procedure = &entity_get(resolver.scopes, id).data.(Procedure_Data)
		procedure.body_state = .Invalid
		return false, nil
	}
	expression_block(checker, view, body.file, procedure_scope, body.node) or_return
	expression_procedure_termination(checker, view, id, body) or_return
	expression_main_convention(checker, view, id, body) or_return
	// Nested literal bodies resolve like top-level ones; drain them here so their diagnostics count for this body. The resolver stack is empty while bodies are checked.
	resolver_check_pending_bodies(resolver) or_return
	procedure = &entity_get(resolver.scopes, id).data.(Procedure_Data)
	procedure.defers = expression_take_defers(checker, defers_first) or_return
	procedure.body_state = .Invalid if expression_diagnostics_within(checker, diagnostics_before, body) else .Complete
	return true, nil
}

// Official check_proc_body: a procedure with results, or declared `-> !`, must end in a terminating statement.
@(private = "file")
expression_procedure_termination :: proc(checker: ^Expression_Checker, view: View_Id, id: Entity_Id, body: Node_Ref) -> Resolve_Error {
	signature := entity_get(checker.type_checker.resolver.scopes, id).data.(Procedure_Data).signature
	if signature == 0 { return nil }
	descriptor := types.get(checker.type_checker.store, signature)
	if descriptor.kind != .Procedure || (len(descriptor.results) == 0 && !descriptor.diverging) { return nil }
	if body_terminates(checker, view, checker.type_checker.files[body.file], body.node) { return nil }
	kind := Expression_Diagnostic_Kind.Missing_Return if len(descriptor.results) != 0 else .Missing_Diverging_Call
	scope := entity_get(checker.type_checker.resolver.scopes, id).scope
	_, err := expression_failure(checker, view, scope, body.node, kind)
	return err
}

// Official check_proc_decl: the entry point of the main package cannot use a custom calling convention.
@(private = "file")
expression_main_convention :: proc(checker: ^Expression_Checker, view: View_Id, id: Entity_Id, body: Node_Ref) -> Resolve_Error {
	scopes := checker.type_checker.resolver.scopes
	entity := entity_get(scopes, id)
	procedure := entity.data.(Procedure_Data)
	scope_kind := scope_get(scopes, entity.scope).kind
	if procedure.source_name != "main" || procedure.convention == .Odin || scope_kind != .Package && scope_kind != .File { return nil }
	package_index := int(entity.package_id)
	if package_index <= 0 || package_index >= len(checker.packages) { return nil }
	if checker.packages[package_index].kind == .Runtime || checker.packages[package_index].name != "main" { return nil }
	_, err := expression_failure(checker, view, entity.scope, body.node, .Main_Calling_Convention)
	return err
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
expression_bodyless_signature_bindings :: proc(
	checker: ^Expression_Checker,
	resolver: ^Resolver,
	id: Entity_Id,
	signature: Node_Ref,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	procedure_scope, scope_error := scope_create(resolver.scopes, entity_get(resolver.scopes, id).scope, .Procedure, id)
	if scope_error != nil { return false, binding_resolve_error(scope_error) }
	outer_results, outer_named_results := checker.results, checker.named_results
	defer { checker.results, checker.named_results = outer_results, outer_named_results }
	expression_signature_bindings(checker, resolver, id, signature, procedure_scope) or_return
	procedure := entity_get(resolver.scopes, id).data.(Procedure_Data)
	view := expression_file_view(checker, signature.file) or_return
	if !(expression_procedure_where(checker, view, procedure_scope, procedure.where_clauses) or_return) { return false, nil }
	descriptor := types.get(checker.type_checker.store, procedure.signature)
	return len(procedure.parameters) == len(descriptor.params), nil
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
	metadata, metadata_error := expression_procedure_info(checker, descriptor.procedure_info)
	assert(metadata_error == .None)
	named_results: []Entity_Id
	if proc_type.params != 0 {
		for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, proc_type.params, syntax.Field_List).list) {
			field := syntax.node_payload(file.ast, field_node, syntax.Field)
			if is_poly_name_field(file, field) { continue }
			if field.names.count == 0 && entity_get(resolver.scopes, id).data.(Procedure_Data).body.node != 0 {
				expression_unsupported(checker, view, scope, field_node, "Parameter_Name") or_return
				return nil
			}
			names := syntax.node_list(file.ast, field.names)
			parameter_flags: Entity_Flags
			if .Using in field.flags { parameter_flags += {.Using, .Parameter, .Immutable} }
			if .C_Vararg in field.flags { parameter_flags += {.C_Variadic} }
			if .Any_Int in field.flags { parameter_flags += {.Any_Integer} }
			for name_index in 0 ..< max(len(names), 1) {
				name_node: syntax.Node_Index
				name := ""
				if len(names) > 0 {
					name_node = names[name_index]
					name = expression_text(file, name_node)
				}
				if len(parameters) >= len(parameter_types) { return nil }
				parameter, create_error := entity_create(
					resolver.scopes,
					Entity {
						name = name,
						kind = .Variable,
						scope = scope,
						state = .Resolved,
						flags = parameter_flags,
						type = parameter_types[len(parameters)],
						declaration = {signature.file, name_node},
						data = Variable_Data{storage = .Local},
					},
				)
				if create_error != nil { return binding_resolve_error(create_error) }
				if name_node != 0 {
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
				}
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
	for parameter in parameters {
		entity := entity_get(resolver.scopes, parameter)
		if .Using not_in entity.flags { continue }
		expression_using_parameter(checker, view, scope, entity.declaration.node, parameter) or_return
	}
	checker.results = result_types
	checker.named_results = named_results
	procedure := &entity_get(resolver.scopes, id).data.(Procedure_Data)
	procedure.parameters = parameters[:]
	if metadata != nil { procedure.defaults = metadata.defaults }
	procedure.results = named_results
	return nil
}

@(private = "package")
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
	// Official handle_parameter_value: a non-constant default is only a bare reference to
	// another entity or the context, re-evaluated at each call. Anything else computed must be
	// a constant; parameters cannot be named here at all.
	if info.entity != 0 || info.mode == .Context || default_argument_is_context_reference(file, node) {
		return Default_Argument{value = Operand(Expression_Ref{view, node})}, nil
	}
	// `typeid_of` never folds to a constant here, although official treats it as one. The
	// value is identical at every call, so re-evaluating it per call preserves behavior until
	// lowering materializes typeid values directly.
	if info.plan != 0 {
		if _, is_typeid := checker.plans[info.plan].(Typeid_Plan); is_typeid {
			return Default_Argument{value = Operand(Expression_Ref{view, node})}, nil
		}
	}
	expression_unsupported(checker, view, scope, node, "Default_Constant") or_return
	return {}, nil
}

// Official check_proc_type: a generic definition checks each default with the parameters bound
// so far. A bare use of a polymorphic parameter, or a compound or procedure literal over one,
// is rejected here; anything else follows the usual constant rule and is re-checked per instance.
@(private = "file")
expression_generic_default_validation :: proc(
	checker: ^Expression_Checker,
	id: Entity_Id,
	declaration: Collected_Declaration,
	scope: Scope_Id,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	valid = true
	file := checker.type_checker.files[declaration.type.file]
	view := expression_file_view(checker, declaration.type.file) or_return
	signature := syntax.node_payload(file.ast, declaration.type.node, syntax.Proc_Type)
	if signature.params == 0 { return true, nil }
	placeholder_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block, id)
	if scope_error != nil { return false, binding_resolve_error(scope_error) }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	poly_names := make([dynamic]string, allocator) or_return
	params := syntax.node_payload(file.ast, signature.params, syntax.Field_List)
	for field_node in syntax.node_list(file.ast, params.list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		// Polymorphic names enter scope left to right: a default sees only earlier ones,
		// whether declared as `$T` parameters or bound by an earlier pattern.
		for name in syntax.node_list(file.ast, field.names) {
			collect_poly_names(file, name, &poly_names) or_return
		}
		collect_poly_names(file, field.type, &poly_names) or_return
		for poly_name in poly_names[:] {
			if scope_lookup_current(checker.type_checker.resolver.scopes, placeholder_scope, poly_name) != 0 { continue }
			bound, create_error := entity_create(
				checker.type_checker.resolver.scopes,
				Entity {
					name = poly_name,
					kind = .Type_Name,
					scope = placeholder_scope,
					package_id = entity_get(checker.type_checker.resolver.scopes, id).package_id,
					state = .Resolved,
					type = checker.default_integer,
				},
			)
			if create_error != nil { return false, binding_resolve_error(create_error) }
			if _, insert_error := scope_insert(checker.type_checker.resolver.scopes, placeholder_scope, bound); insert_error != nil {
				return false, binding_resolve_error(insert_error)
			}
		}
		if field.default_value == 0 { continue }
		default_node := type_unparen(file, field.default_value)
		if default_argument_is_poly_name(file, default_node, poly_names[:]) {
			expression_unsupported(checker, view, placeholder_scope, field.default_value, "Default_Polymorphic_Constant") or_return
			valid = false
			continue
		}
		if file.ast.nodes[default_node].kind == .Comp_Lit &&
		   default_node_mentions_poly_param(file, syntax.node_payload(file.ast, default_node, syntax.Comp_Lit).type, poly_names[:]) {
			expression_unsupported(checker, view, placeholder_scope, field.default_value, "Default_Polymorphic_Compound") or_return
			valid = false
			continue
		}
		if file.ast.nodes[default_node].kind == .Proc_Lit {
			literal := syntax.node_payload(file.ast, default_node, syntax.Proc_Lit)
			#partial switch file.ast.nodes[literal.type].kind {
			case .Proc_Type:
				if default_node_mentions_poly_param(file, literal.type, poly_names[:]) {
					expression_unsupported(checker, view, placeholder_scope, field.default_value, "Default_Polymorphic_Procedure") or_return
					valid = false
				}
				// A clean literal is left for the instances: its body belongs to them.
				continue
			}
		}
		// A `typeid_of` over a polymorphic parameter never folds here, although it is
		// constant once instantiated. Official rejects it at the definition.
		if default_node_mentions_poly_param(file, default_node, poly_names[:]) && default_argument_is_typeid_of(file, default_node) {
			expression_unsupported(checker, view, placeholder_scope, field.default_value, "Default_Constant") or_return
			valid = false
			continue
		}
		hint := types.Type_Id(0)
		if field.type != 0 && !default_node_mentions_poly_param(file, field.type, poly_names[:]) {
			hint = type_expression(checker.type_checker, declaration.type.file, placeholder_scope, field.type, true) or_return
			if hint == types.TYPE_POISON {
				valid = false
				continue
			}
		}
		argument := expression_default_argument(checker, view, placeholder_scope, field.default_value, hint) or_return
		if argument.value == nil && !argument.caller_location && !argument.caller_expression { valid = false }
	}
	return valid, nil
}

// A bare polymorphic name used as a default value.
@(private = "file")
default_argument_is_poly_name :: proc(file: ^File, node: syntax.Node_Index, poly_names: []string) -> bool {
	kind := file.ast.nodes[node].kind
	if kind != .Ident && kind != .Poly_Type { return false }
	name := node
	if kind == .Poly_Type { name = syntax.node_payload(file.ast, node, syntax.Poly_Type).type }
	text := expression_text(file, name)
	for poly_name in poly_names {
		if poly_name == text { return true }
	}
	return false
}

// Whether a type expression mentions a polymorphic parameter, as an explicit `$T` or as a
// plain identifier naming one. Supplements poly_pattern_has_poly, which ignores identifiers.
// Collects the polymorphic names a signature binds, whether declared as `$T` parameters or
// bound by an earlier pattern, so a default sees only the parameters bound before it.
@(private = "file")
collect_poly_names :: proc(file: ^File, node: syntax.Node_Index, poly_names: ^[dynamic]string) -> runtime.Allocator_Error {
	target := type_unparen(file, node)
	if target == 0 { return nil }
	#partial switch file.ast.nodes[target].kind {
	case .Poly_Type:
		append(poly_names, expression_text(file, syntax.node_payload(file.ast, target, syntax.Poly_Type).type)) or_return
	case .Call_Expr:
		call := syntax.node_payload(file.ast, target, syntax.Call_Expr)
		collect_poly_names(file, call.expr, poly_names) or_return
		for argument in syntax.node_list(file.ast, call.args) {
			collect_poly_names(file, argument, poly_names) or_return
		}
	case .Pointer_Type:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Pointer_Type).elem, poly_names) or_return
	case .Multi_Pointer_Type:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Multi_Pointer_Type).elem, poly_names) or_return
	case .Dynamic_Array_Type:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Dynamic_Array_Type).elem, poly_names) or_return
	case .Array_Type:
		array := syntax.node_payload(file.ast, target, syntax.Array_Type)
		collect_poly_names(file, array.elem, poly_names) or_return
		collect_poly_names(file, array.len, poly_names) or_return
	case .Paren_Expr:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Paren_Expr).expr, poly_names) or_return
	case .Selector_Expr:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Selector_Expr).expr, poly_names) or_return
	case .Map_Type:
		map_type := syntax.node_payload(file.ast, target, syntax.Map_Type)
		collect_poly_names(file, map_type.key, poly_names) or_return
		collect_poly_names(file, map_type.value, poly_names) or_return
	case .Field_Value:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Field_Value).value, poly_names) or_return
	case .Ellipsis:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Ellipsis).expr, poly_names) or_return
	case .Typeid_Type:
		collect_poly_names(file, syntax.node_payload(file.ast, target, syntax.Typeid_Type).specialization, poly_names) or_return
	}
	return nil
}

@(private = "file")
default_node_mentions_poly_param :: proc(file: ^File, node: syntax.Node_Index, poly_names: []string) -> bool {
	unparen := type_unparen(file, node)
	if unparen == 0 { return false }
	if poly_pattern_has_poly(file, unparen) { return true }
	#partial switch file.ast.nodes[unparen].kind {
	case .Ident:
		text := expression_text(file, unparen)
		for poly_name in poly_names {
			if poly_name == text { return true }
		}
	case .Paren_Expr:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Paren_Expr).expr, poly_names)
	case .Selector_Expr:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Selector_Expr).expr, poly_names)
	case .Call_Expr:
		call := syntax.node_payload(file.ast, unparen, syntax.Call_Expr)
		if default_node_mentions_poly_param(file, call.expr, poly_names) { return true }
		for argument in syntax.node_list(file.ast, call.args) {
			if default_node_mentions_poly_param(file, argument, poly_names) { return true }
		}
	case .Pointer_Type:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Pointer_Type).elem, poly_names)
	case .Multi_Pointer_Type:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Multi_Pointer_Type).elem, poly_names)
	case .Dynamic_Array_Type:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Dynamic_Array_Type).elem, poly_names)
	case .Array_Type:
		array := syntax.node_payload(file.ast, unparen, syntax.Array_Type)
		return default_node_mentions_poly_param(file, array.elem, poly_names) || default_node_mentions_poly_param(file, array.len, poly_names)
	case .Ellipsis:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Ellipsis).expr, poly_names)
	case .Map_Type:
		map_type := syntax.node_payload(file.ast, unparen, syntax.Map_Type)
		return default_node_mentions_poly_param(file, map_type.key, poly_names) || default_node_mentions_poly_param(file, map_type.value, poly_names)
	case .Typeid_Type:
		return default_node_mentions_poly_param(file, syntax.node_payload(file.ast, unparen, syntax.Typeid_Type).specialization, poly_names)
	case .Proc_Type:
		signature := syntax.node_payload(file.ast, unparen, syntax.Proc_Type)
		for list_node in ([2]syntax.Node_Index{signature.params, signature.results}) {
			if list_node == 0 { continue }
			for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, list_node, syntax.Field_List).list) {
				field := syntax.node_payload(file.ast, field_node, syntax.Field)
				for name in syntax.node_list(file.ast, field.names) {
					if default_node_mentions_poly_param(file, name, poly_names) { return true }
				}
				if default_node_mentions_poly_param(file, field.type, poly_names) || default_node_mentions_poly_param(file, field.default_value, poly_names) {
					return true
				}
			}
		}
	}
	return false
}

// A selector chain rooted at `context`, as `context.allocator` is. The selector itself
// checks as a variable with no entity, so the root is found syntactically.
@(private = "file")
default_argument_is_typeid_of :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	current := type_unparen(file, node)
	if current == 0 || file.ast.nodes[current].kind != .Call_Expr { return false }
	callee := type_unparen(file, syntax.node_payload(file.ast, current, syntax.Call_Expr).expr)
	return callee != 0 && file.ast.nodes[callee].kind == .Ident && expression_text(file, callee) == "typeid_of"
}

@(private = "file")
default_argument_is_context_reference :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	current := node
	for {
		#partial switch file.ast.nodes[current].kind {
		case .Implicit:
			return syntax.node_payload(file.ast, current, syntax.Implicit).kind == .Context
		case .Selector_Expr:
			current = syntax.node_payload(file.ast, current, syntax.Selector_Expr).expr
		case .Paren_Expr:
			current = syntax.node_payload(file.ast, current, syntax.Paren_Expr).expr
		case:
			return false
		}
	}
}

expression_block :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	block := syntax.node_payload(file.ast, node, syntax.Block_Stmt)
	block_scope, scope_error := scope_create(checker.type_checker.resolver.scopes, scope, .Block)
	if scope_error != nil { return binding_resolve_error(scope_error) }
	statements := syntax.node_list(file.ast, block.stmts)
	expression_predeclare_constants(checker, view, file_id, block_scope, statements) or_return
	for statement in statements {
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
	case .Type_Switch_Stmt:
		return expression_type_switch(checker, view, file_id, scope, node)
	case .When_Stmt:
		return expression_when(checker, view, file_id, scope, node)
	case .Branch_Stmt:
		return expression_branch(checker, view, file_id, scope, node)
	case .Assign_Stmt:
		return expression_assignment(checker, view, file_id, scope, node)
	case .Using_Stmt:
		return expression_using_statement(checker, view, file_id, scope, node)
	case .Return_Stmt:
		return expression_return(checker, view, file_id, scope, node)
	case .Defer_Stmt:
		return expression_defer(checker, view, file_id, scope, node)
	case .Range_Stmt:
		return expression_range(checker, view, file_id, scope, node)
	case .Unroll_Range_Stmt:
		return expression_unroll_range(checker, view, file_id, scope, node)
	case .Expr_Stmt:
		expression := syntax.node_payload(file.ast, node, syntax.Expr_Stmt).expr
		_ = check_expression(checker, view, scope, expression) or_return
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
	if file.ast.nodes[left[0]].kind == .Implicit { mark_context_assignment(checker, scope) }
	destination := check_expression(checker, view, scope, left[0]) or_return
	if destination.state == .Invalid { return nil }
	if !expression_assignable(checker, destination) {
		expression_unsupported(checker, view, scope, left[0], "Assign_Destination_Mode") or_return
		return nil
	}
	if assignment.op.kind == .Cmp_And_Eq || assignment.op.kind == .Cmp_Or_Eq {
		destination_kind := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, destination.type)).kind
		if !conversion_boolean(destination_kind) {
			_, failure := expression_failure(checker, view, scope, node, .Invalid_Operator)
			return failure
		}
	}
	value_hint := destination.type
	if assignment.op.kind == .Shl_Eq || assignment.op.kind == .Shr_Eq { value_hint = 0 }
	value := check_expression(checker, view, scope, right[0], value_hint) or_return
	if value.state == .Invalid { return nil }
	if value_hint == 0 && conversion_untyped(types.get(checker.type_checker.store, value.type).kind) {
		value = check_expression(checker, view, scope, right[0], types.default_type_of_untyped(checker.type_checker.store, value.type)) or_return
		if value.state == .Invalid { return nil }
	}
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
	if len(values) == 1 && len(checker.results) > 1 {
		handled := expression_returned_call(checker, view, scope, node, values[0]) or_return
		if handled { return nil }
	}
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
local_variable_data :: proc(
	checker: ^Expression_Checker,
	file_id: File_Id,
	attributes: syntax.Node_Range,
	values: []syntax.Node_Index,
	name_count, index: int,
) -> Variable_Data {
	file := checker.type_checker.files[file_id]
	if !collection_has_attribute(file.ast, file.source, attributes, "static") { return Variable_Data{storage = .Local} }
	data := Variable_Data {
		storage = .Global,
	}
	if len(values) == name_count { data.initializer = Node_Ref{file_id, values[index]} }
	return data
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
		if target == types.TYPE_POISON {
			variable_types := make([]types.Type_Id, len(names), mem.dynamic_arena_allocator(&checker.arena)) or_return
			for &variable_type in variable_types { variable_type = types.TYPE_POISON }
			return expression_bind_local_declaration(checker, view, file_id, scope, declaration, variable_types)
		}
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	variable_types := make([]types.Type_Id, len(names), allocator) or_return
	conversions := make([]Plan_Id, len(values), allocator) or_return
	if multi {
		value := check_expression(checker, view, scope, values[0]) or_return
		if value.state == .Invalid {
			for &variable_type in variable_types { variable_type = types.TYPE_POISON }
		} else {
			results: []types.Type_Id
			is_call := false
			is_assertion_results := false
			if value.plan != 0 {
				if value_type, is_pair := comma_ok_value_type(checker, value, len(names) == 2); is_pair {
					variable_types[0], variable_types[1] = value_type, checker.boolean
					is_call, is_assertion_results = true, true
				}
				#partial switch plan in checker.plans[value.plan] {
				case Call_Plan:
					results, is_call = plan.results, true
				case Builtin_Plan:
					results, is_call = plan.results, true
				case Propagation_Plan:
					if len(plan.results) > 0 { results, is_call = plan.results, true }
				}
			}
			if !is_call || target != 0 || (!is_assertion_results && len(results) != len(names)) {
				expression_unsupported(checker, view, scope, values[0], "Local_Declaration_Results") or_return
				return nil
			}
			for result, index in results { variable_types[index] = result }
		}
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
		if value.state == .Invalid {
			variable_types[index] = target if target != 0 else types.TYPE_POISON
			continue
		}
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
		case .Untyped_Float, .Untyped_Rune, .Untyped_Complex, .Untyped_Quaternion:
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
	return expression_bind_local_declaration(checker, view, file_id, scope, declaration, variable_types)
}

@(private = "file")
expression_bind_local_declaration :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	declaration: syntax.Value_Decl,
	variable_types: []types.Type_Id,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	names := syntax.node_list(file.ast, declaration.names)
	values := syntax.node_list(file.ast, declaration.values)
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
				data = local_variable_data(checker, file_id, declaration.attributes, values, len(names), index),
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

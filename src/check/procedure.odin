package check

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "oc:syntax"
import "oc:types"

// Every declaration attribute the official compiler accepts on a value
// declaration or a foreign block. Anything outside this set is rejected
// instead of being silently ignored.
@(private = "package")
declaration_attribute_known :: proc(name: string) -> bool {
	switch name {
	case "tag",
	     "private",
	     "test",
	     "export",
	     "require",
	     "require_results",
	     "linkage",
	     "link_name",
	     "link_prefix",
	     "link_suffix",
	     "link_section",
	     "init",
	     "fini",
	     "deprecated",
	     "disabled",
	     "cold",
	     "optimization_mode",
	     "static",
	     "rodata",
	     "thread_local",
	     "align",
	     "builtin",
	     "default_calling_convention",
	     "deferred",
	     "deferred_none",
	     "deferred_in",
	     "deferred_out",
	     "deferred_in_out",
	     "deferred_in_by_ptr",
	     "deferred_out_by_ptr",
	     "deferred_in_out_by_ptr",
	     "objc_name",
	     "objc_is_class_method",
	     "objc_type",
	     "objc_implement",
	     "objc_selector",
	     "objc_class",
	     "objc_superclass",
	     "objc_ivar",
	     "objc_context_provider",
	     "raddbg_type_view",
	     "entry_point_only",
	     "no_instrumentation",
	     "instrumentation_enter",
	     "instrumentation_exit",
	     "no_sanitize_address",
	     "no_sanitize_memory",
	     "no_sanitize_thread",
	     "fast_math",
	     "futex",
	     "synchronizes",
	     "synchronizes_shared",
	     "futex_parameter",
	     "require_target_feature",
	     "enable_target_feature":
		return true
	}
	return false
}

@(private = "package")
deferred_attribute_kind :: proc(name: string) -> Deferred_Kind {
	switch name {
	case "deferred":
		return .Legacy
	case "deferred_none":
		return .None
	case "deferred_in":
		return .In
	case "deferred_out":
		return .Out
	case "deferred_in_out":
		return .In_Out
	case "deferred_in_by_ptr", "deferred_out_by_ptr", "deferred_in_out_by_ptr":
		return .By_Ptr
	}
	return .Absent
}

// Resolved deferred target recorded on a procedure entity, if any.
@(private = "package")
procedure_deferred_target :: proc(scopes: ^Scope_Store, id: Entity_Id) -> Entity_Id {
	entity := entity_get(scopes, id)
	if entity == nil { return 0 }
	for attribute in entity.attributes {
		if deferred_attribute_kind(attribute.name) != .Absent && deferred_attribute_kind(attribute.name) != .Legacy {
			return attribute.entity
		}
	}
	return 0
}

@(private = "file")
Deferred_Attribute :: struct {
	kind:    Deferred_Kind,
	name:    string,
	element: syntax.Node_Index,
	value:   syntax.Node_Index,
}

@(private = "file")
deferred_attribute_element :: proc(file: ^File, element: syntax.Node_Index) -> (selected: Deferred_Attribute) {
	name_node := element
	value: syntax.Node_Index
	if file.ast.nodes[element].kind == .Field_Value {
		field := syntax.node_payload(file.ast, element, syntax.Field_Value)
		name_node, value = field.field, field.value
	}
	name := expression_text(file, name_node)
	return {kind = deferred_attribute_kind(name), name = name, element = element, value = value}
}

@(private = "file")
deferred_target_error :: proc(checker: ^Expression_Checker, view: View_Id, scope: Scope_Id, node: syntax.Node_Index, attribute_name: string) -> Resolve_Error {
	_, err := expression_unsupported(
		checker,
		view,
		scope,
		node,
		fmt.aprintf("Expected a procedure entity for '%s'", attribute_name, allocator = mem.dynamic_arena_allocator(&checker.arena)),
	)
	return err
}

// Validates the deferred_* attribute on a procedure declaration and records
// the resolved target on the entity. Runs after the body so forward
// references and nested literal targets already exist.
@(private = "file")
expression_deferred_attribute :: proc(checker: ^Expression_Checker, id: Entity_Id) -> (valid: bool, err: Resolve_Error) {
	scopes := checker.type_checker.resolver.scopes
	entity := entity_get(scopes, id)
	data, is_procedure := entity.data.(Procedure_Data)
	if !is_procedure || entity.kind != .Procedure { return true, nil }
	if procedure_deferred_target(scopes, id) != 0 { return true, nil }
	if entity.declaration.node == 0 { return true, nil }
	file := checker.type_checker.files[entity.declaration.file]
	if file.ast.nodes[entity.declaration.node].kind != .Value_Decl { return true, nil }
	decl := syntax.node_payload(file.ast, entity.declaration.node, syntax.Value_Decl)
	view := expression_file_view(checker, entity.declaration.file) or_return
	scope := entity.scope
	seen := Deferred_Kind.Absent
	seen_name := ""
	seen_element, seen_value: syntax.Node_Index
	for attribute in syntax.node_list(file.ast, decl.attributes) {
		for element in syntax.node_list(file.ast, syntax.node_payload(file.ast, attribute, syntax.Attribute).elems) {
			selected := deferred_attribute_element(file, element)
			if !declaration_attribute_known(selected.name) {
				expression_unsupported(
					checker,
					view,
					scope,
					element,
					fmt.aprintf("Unknown attribute element name '%s'", selected.name, allocator = mem.dynamic_arena_allocator(&checker.arena)),
				) or_return
				return false, nil
			}
			if selected.kind == .Absent { continue }
			if seen != .Absent {
				expression_unsupported(checker, view, scope, element, "Previous usage of a 'deferred_*' attribute") or_return
				return false, nil
			}
			seen, seen_name, seen_element, seen_value = selected.kind, selected.name, element, selected.value
		}
	}
	if seen == .Absent { return true, nil }
	if seen == .Legacy {
		expression_unsupported(
			checker,
			view,
			scope,
			seen_element,
			"'deferred' is not allowed any more, please use one of the following instead: 'deferred_none', 'deferred_in', 'deferred_out'",
		) or_return
		return false, nil
	}
	if seen_value == 0 || file.ast.nodes[seen_value].kind != .Ident {
		deferred_target_error(checker, view, scope, seen_value if seen_value != 0 else seen_element, seen_name) or_return
		return false, nil
	}
	target, _ := scope_lookup(scopes, scope, expression_text(file, seen_value))
	if target == 0 {
		deferred_target_error(checker, view, scope, seen_element, seen_name) or_return
		return false, nil
	}
	if target == id {
		expression_unsupported(
			checker,
			view,
			scope,
			seen_element,
			fmt.aprintf(
				"'%s' cannot be used as its own %s",
				entity_get(scopes, target).data.(Procedure_Data).source_name,
				seen_name,
				allocator = mem.dynamic_arena_allocator(&checker.arena),
			),
		) or_return
		return false, nil
	}
	state, resolve_error := resolve_entity(checker.type_checker.resolver, target)
	if resolve_error != nil { return false, resolve_error }
	if state == .Invalid { return false, nil }
	if binding := entity_get(scopes, target); binding.kind == .Constant && binding.alias != 0 { target = binding.alias }
	entity = entity_get(scopes, id)
	target_entity := entity_get(scopes, target)
	target_data, target_is_procedure := target_entity.data.(Procedure_Data)
	if !target_is_procedure || target_entity.kind != .Procedure {
		deferred_target_error(checker, view, scope, seen_element, seen_name) or_return
		return false, nil
	}
	if procedure_deferred_target(scopes, target) != 0 {
		expression_unsupported(
			checker,
			view,
			scope,
			seen_element,
			fmt.aprintf(
				"Deferred procedure '%s' cannot be used as the target of '%s' because it has a deferred procedure itself (deferred procedure chaining is not allowed)",
				target_data.source_name,
				entity.data.(Procedure_Data).source_name,
				allocator = mem.dynamic_arena_allocator(&checker.arena),
			),
		) or_return
		return false, nil
	}
	if seen == .By_Ptr {
		expression_unsupported(
			checker,
			view,
			scope,
			seen_element,
			fmt.aprintf("Procedure attribute '%s' is not supported", seen_name, allocator = mem.dynamic_arena_allocator(&checker.arena)),
		) or_return
		return false, nil
	}
	if !data.generic && !target_data.generic {
		name := syntax.node_list(file.ast, decl.names)[0]
		if !(expression_deferred_signature(checker, view, scope, entity, target_entity, seen, seen_name, name) or_return) { return false, nil }
		entity = entity_get(scopes, id)
	}
	span := file.ast.nodes[seen_element]
	arena_attributes := mem.dynamic_arena_allocator(&checker.arena)
	recorded := make([]Attribute, len(entity.attributes) + 1, arena_attributes) or_return
	copy(recorded, entity.attributes)
	recorded[len(entity.attributes)] = Attribute {
		name   = seen_name,
		entity = target,
		source = {entity.declaration.file, span.start, span.end},
	}
	entity.attributes = recorded
	return true, nil
}

// Matches the deferred target parameters against the annotated procedure's
// inputs or results, with the official diagnostics.
@(private = "file")
expression_deferred_signature :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	entity, target: ^Entity,
	kind: Deferred_Kind,
	attribute_name: string,
	element: syntax.Node_Index,
) -> (
	match: bool,
	err: Resolve_Error,
) {
	arena := mem.dynamic_arena_allocator(&checker.arena)
	store := checker.type_checker.store
	source := types.get(store, entity.type)
	destination := types.get(store, target.type)
	if source.kind != .Procedure || destination.kind != .Procedure { return false, nil }
	source_name := entity.data.(Procedure_Data).source_name
	target_name := target.data.(Procedure_Data).source_name
	if kind == .None {
		if len(destination.params) != 0 {
			expression_unsupported(
				checker,
				view,
				scope,
				element,
				fmt.aprintf("Deferred procedure '%s' must have no input parameters", target_name, allocator = arena),
			) or_return
			return false, nil
		}
		return true, nil
	}
	have: []types.Type_Id
	word := "results"
	if kind == .In {
		have, word = source.params, "inputs"
	} else if kind == .Out {
		have = source.results
	} else {
		if len(destination.params) == 0 {
			expression_unsupported(
				checker,
				view,
				scope,
				element,
				fmt.aprintf("Deferred procedure must have parameters for %s", attribute_name, allocator = arena),
			) or_return
			return false, nil
		}
		have = make([]types.Type_Id, len(source.params) + len(source.results), arena) or_return
		copy(have, source.params)
		copy(have[len(source.params):], source.results)
	}
	want := destination.params
	if len(have) == 0 && len(want) == 0 { return true, nil }
	detail := ""
	if len(have) != 0 && len(want) != 0 {
		identical := len(have) == len(want)
		for have_type, index in have {
			if !identical { break }
			identical = types.are_identical(store, have_type, want[index])
		}
		if identical { return true, nil }
		detail = fmt.aprintf(": %s =/= %s", deferred_tuple_text(store, want, arena), deferred_tuple_text(store, have, arena), allocator = arena)
	}
	expression_unsupported(
		checker,
		view,
		scope,
		element,
		fmt.aprintf(
			"Deferred procedure '%s' parameters do not match the %s of initial procedure '%s'%s",
			target_name,
			word,
			source_name,
			detail,
			allocator = arena,
		),
	) or_return
	return false, nil
}

@(private = "file")
deferred_tuple_text :: proc(store: ^types.Store, list: []types.Type_Id, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_byte(&builder, '(')
	for id, index in list {
		if index > 0 { strings.write_string(&builder, ", ") }
		strings.write_string(&builder, record_type_name(store, id, allocator))
	}
	strings.write_byte(&builder, ')')
	return strings.to_string(builder)
}

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
	require_target_feature, enable_target_feature := check_procedure_target_features(checker, scope, id) or_return
	if syntax.node_payload(checker.type_checker.files[declaration.type.file].ast, declaration.type.node, syntax.Proc_Type).generic {
		procedure := &entity_get(resolver.scopes, id).data.(Procedure_Data)
		procedure.generic = true
		check_atomic_attributes(checker, id, declaration.identifier.node, declaration.type.node, 0) or_return
		return expression_generic_default_validation(checker, id, declaration, scope)
	}
	signature := type_expression(checker.type_checker, declaration.type.file, scope, declaration.type.node, true) or_return
	if signature == types.TYPE_POISON { return false, nil }
	descriptor := types.get(checker.type_checker.store, signature)
	if info, info_error := expression_procedure_info(checker, descriptor.procedure_info); info_error == .None && info != nil {
		info.require_target_feature, info.enable_target_feature = require_target_feature, enable_target_feature
	}
	entity := entity_get(resolver.scopes, id)
	procedure := &entity.data.(Procedure_Data)
	procedure.signature = signature
	procedure.convention = descriptor.convention
	procedure.variadic_index = procedure_variadic_index(checker.type_checker.files[declaration.type.file], declaration.type.node)
	entity.type = signature
	check_atomic_attributes(checker, id, declaration.identifier.node, declaration.type.node, signature) or_return
	entity = entity_get(resolver.scopes, id)
	_, is_init := declaration_attribute(checker, entity^, "init") or_return
	_, is_fini := declaration_attribute(checker, entity^, "fini") or_return
	if is_init || is_fini {
		attribute := "init" if is_init else "fini"
		file := checker.type_checker.files[declaration.identifier.file]
		global_context := false
		for feature in file.policy.features { global_context ||= feature == "global-context" }
		if !global_context && descriptor.convention != .Contextless {
			expression_unsupported(
				checker,
				view,
				scope,
				declaration.identifier.node,
				fmt.aprintf("@(%s) procedures must be declared as \"contextless\"", attribute, allocator = mem.dynamic_arena_allocator(&checker.arena)),
			) or_return
			return false, nil
		}
	}
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
	outer_bounds_check_policy := checker.bounds_check_policy
	outer_type_assert_policy := checker.type_assert_policy
	checker.defer_depth, checker.bounds_check_policy = 0, .Unspecified
	checker.type_assert_policy = .Unspecified
	proc_type := syntax.node_payload(checker.type_checker.files[signature.file].ast, signature.node, syntax.Proc_Type)
	if .No_Bounds_Check in proc_type.tags { checker.bounds_check_policy = .Disabled }
	if .Bounds_Check in proc_type.tags { checker.bounds_check_policy = .Enabled }
	if .No_Type_Assert in proc_type.tags { checker.type_assert_policy = .Disabled }
	if .Type_Assert in proc_type.tags { checker.type_assert_policy = .Enabled }
	defer {
		delete(checker.control)
		checker.control = outer_control
		checker.defer_depth = outer_defer_depth
		checker.bounds_check_policy = outer_bounds_check_policy
		checker.type_assert_policy = outer_type_assert_policy
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
	if !(expression_deferred_attribute(checker, id) or_return) {
		procedure = &entity_get(resolver.scopes, id).data.(Procedure_Data)
		procedure.body_state = .Invalid
		return false, nil
	}
	procedure = &entity_get(resolver.scopes, id).data.(Procedure_Data)
	procedure.defers = expression_take_defers(checker, defers_first) or_return
	procedure.body_state = .Invalid if expression_diagnostics_within(checker, diagnostics_before, body) else .Complete
	return true, nil
}

@(private = "package")
expression_queue_instance_body :: proc(
	checker: ^Expression_Checker,
	resolver: ^Resolver,
	id: Entity_Id,
	declaration: Collected_Declaration,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	if !(expression_bodyless_signature_bindings(checker, resolver, id, declaration.type) or_return) { return false, nil }
	checker.type_checker.declarations[id] = declaration
	_, append_error := append(&resolver.pending_bodies, id)
	return true, append_error
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
	if checker.no_entry_point { return nil }
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
		if diagnostic.severity == .Warning && !checker.options.warnings_as_errors { continue }
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
	if !(expression_deferred_attribute(checker, id) or_return) { return false, nil }
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
	result_defaults: []Default_Argument
	if proc_type.params != 0 {
		for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, proc_type.params, syntax.Field_List).list) {
			field := syntax.node_payload(file.ast, field_node, syntax.Field)
			if is_poly_name_field(file, field) { continue }
			if field.names.count == 0 && entity_get(resolver.scopes, id).data.(Procedure_Data).body.node != 0 {
				expression_unsupported(checker, view, scope, field_node, "Parameter_Name") or_return
				return nil
			}
			names := syntax.node_list(file.ast, field.names)
			parameter_flags: Entity_Flags = {.Used}
			if .Using in field.flags { parameter_flags += {.Using, .Parameter, .Immutable} }
			if .C_Vararg in field.flags { parameter_flags += {.C_Variadic} }
			if .Any_Int in field.flags { parameter_flags += {.Any_Integer} }
			if .No_Broadcast in field.flags { parameter_flags += {.No_Broadcast} }
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
		bindings, defaults, bound, bind_error := expression_result_bindings(checker, resolver, view, signature.file, scope, proc_type.results, result_types)
		if bind_error != nil { return bind_error }
		if !bound { return nil }
		named_results = bindings
		result_defaults = defaults
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
	procedure.result_defaults = result_defaults
	return nil
}

@(private = "package")
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
	expression_deferred_tail_check(checker, view, file_id, block_scope, statements) or_return
	return nil
}

// A scope ending in a diverging call after a deferred call is a check error:
// the registered defer would never run. Mirrors the tail of the official
// check_block, including its sibling unreachable-defer diagnostic.
@(private = "file")
expression_deferred_tail_check :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	statements: []syntax.Node_Index,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	end := len(statements)
	for end > 0 {
		kind := file.ast.nodes[statements[end - 1]].kind
		if kind == .Empty_Stmt { end -= 1; continue }
		if kind == .Value_Decl && !syntax.node_payload(file.ast, statements[end - 1], syntax.Value_Decl).is_mutable { end -= 1; continue }
		break
	}
	if end == 0 { return nil }
	last := statements[end - 1]
	if file.ast.nodes[last].kind != .Expr_Stmt { return nil }
	call := syntax.node_payload(file.ast, last, syntax.Expr_Stmt).expr
	for file.ast.nodes[call].kind == .Paren_Expr {
		call = syntax.node_payload(file.ast, call, syntax.Paren_Expr).expr
	}
	if file.ast.nodes[call].kind != .Call_Expr || !expression_is_diverging_call(checker, view, call) { return nil }
	for statement in statements[:end - 1] {
		if file.ast.nodes[statement].kind == .Defer_Stmt {
			expression_unsupported(
				checker,
				view,
				scope,
				statement,
				"Unreachable defer statement due to diverging procedure call at the end of the current scope",
			) or_return
			continue
		}
		if block_statement_has_deferred_call(checker, view, file, statement) {
			expression_unsupported(
				checker,
				view,
				scope,
				statement,
				"Unreachable deferred procedure call due to a diverging procedure call at the end of the current scope",
			) or_return
		}
	}
	return nil
}

// Whether a call expression diverges: a diverging callee or a diverging builtin.
@(private = "file")
expression_is_diverging_call :: proc(checker: ^Expression_Checker, view: View_Id, node: syntax.Node_Index) -> bool {
	plan := expression_stored_info(checker, view, node).plan
	if plan == 0 { return false }
	#partial switch specific in checker.plans[plan] {
	case Builtin_Plan:
		#partial switch checker.builtin_kinds[specific.builtin] {
		case .Trap, .Unreachable, .Debug_Trap:
			return true
		}
	case Call_Plan:
		if specific.entity == 0 { return false }
		type := entity_get(checker.type_checker.resolver.scopes, specific.entity).type
		if type == 0 { return false }
		store := checker.type_checker.store
		descriptor := types.get(store, types.resolve_named(store, type))
		return descriptor.kind == .Procedure && descriptor.diverging
	}
	return false
}

@(private = "file")
block_statement_has_deferred_call :: proc(checker: ^Expression_Checker, view: View_Id, file: ^File, node: syntax.Node_Index) -> bool {
	#partial switch file.ast.nodes[node].kind {
	case .Expr_Stmt:
		return expression_has_deferred_call(checker, view, file, syntax.node_payload(file.ast, node, syntax.Expr_Stmt).expr)
	case .Assign_Stmt:
		assignment := syntax.node_payload(file.ast, node, syntax.Assign_Stmt)
		for side in syntax.node_list(file.ast, assignment.lhs) {
			if expression_has_deferred_call(checker, view, file, side) { return true }
		}
		for side in syntax.node_list(file.ast, assignment.rhs) {
			if expression_has_deferred_call(checker, view, file, side) { return true }
		}
	case .Value_Decl:
		for value in syntax.node_list(file.ast, syntax.node_payload(file.ast, node, syntax.Value_Decl).values) {
			if expression_has_deferred_call(checker, view, file, value) { return true }
		}
	}
	return false
}

// Whether an expression holds a call to a procedure annotated with
// deferred_*. Presence is textual so ordering cannot hide it; validity is
// diagnosed separately where the procedure is declared.
@(private = "file")
expression_has_deferred_call :: proc(checker: ^Expression_Checker, view: View_Id, file: ^File, node: syntax.Node_Index) -> bool {
	current := node
	for file.ast.nodes[current].kind == .Paren_Expr {
		current = syntax.node_payload(file.ast, current, syntax.Paren_Expr).expr
	}
	if file.ast.nodes[current].kind != .Call_Expr { return false }
	call := syntax.node_payload(file.ast, current, syntax.Call_Expr)
	if expression_has_deferred_call(checker, view, file, call.expr) { return true }
	for argument in syntax.node_list(file.ast, call.args) {
		if expression_has_deferred_call(checker, view, file, argument) { return true }
	}
	return call_callee_has_deferred_attribute(checker, view, current)
}

@(private = "file")
call_callee_has_deferred_attribute :: proc(checker: ^Expression_Checker, view: View_Id, node: syntax.Node_Index) -> bool {
	plan := expression_stored_info(checker, view, node).plan
	if plan == 0 { return false }
	call, is_call := checker.plans[plan].(Call_Plan)
	if !is_call || call.entity == 0 { return false }
	target := entity_get(checker.type_checker.resolver.scopes, call.entity)
	if target.kind != .Procedure || target.declaration.node == 0 { return false }
	declaration_file := checker.type_checker.files[target.declaration.file]
	if declaration_file.ast.nodes[target.declaration.node].kind != .Value_Decl { return false }
	declaration := syntax.node_payload(declaration_file.ast, target.declaration.node, syntax.Value_Decl)
	for attribute in syntax.node_list(declaration_file.ast, declaration.attributes) {
		for element in syntax.node_list(declaration_file.ast, syntax.node_payload(declaration_file.ast, attribute, syntax.Attribute).elems) {
			name := element
			if declaration_file.ast.nodes[element].kind == .Field_Value {
				name = syntax.node_payload(declaration_file.ast, element, syntax.Field_Value).field
			}
			span := declaration_file.ast.nodes[name]
			if deferred_attribute_kind(string(declaration_file.source[span.start:span.end])) != .Absent {
				return true
			}
		}
	}
	return false
}

expression_statement :: proc(checker: ^Expression_Checker, view: View_Id, file_id: File_Id, scope: Scope_Id, node: syntax.Node_Index) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	// As check_stmt in the official compiler: a statement's #no_bounds_check or #bounds_check applies to the whole statement.
	bounds_check_policy := checker.bounds_check_policy
	defer checker.bounds_check_policy = bounds_check_policy
	if .No_Bounds_Check in file.ast.nodes[node].flags {
		checker.bounds_check_policy = .Disabled
	} else if .Bounds_Check in file.ast.nodes[node].flags {
		checker.bounds_check_policy = .Enabled
	}
	type_assert_policy := checker.type_assert_policy
	defer checker.type_assert_policy = type_assert_policy
	if .No_Type_Assert in file.ast.nodes[node].flags {
		checker.type_assert_policy = .Disabled
	} else if .Type_Assert in file.ast.nodes[node].flags {
		checker.type_assert_policy = .Enabled
	}
	#partial switch file.ast.nodes[node].kind {
	case .Empty_Stmt, .Foreign_Block_Decl:
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
	if value.mode == .Type {
		_, failure := expression_type_context_failure(checker, view, scope, right[0], destination.type, value.type, "assignment")
		return failure
	}
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
		if info.mode == .Type {
			_, failure := expression_type_context_failure(
				checker,
				view,
				scope,
				value,
				checker.results[index],
				info.type,
				"return statement",
				"\tSuggestion: If this is intended, make it explicit with a conversion to 'rawptr' or 'uintptr', or a 'transmute'",
			)
			return failure
		}
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
	view: View_Id,
	attributes: syntax.Node_Range,
	values: []syntax.Node_Index,
	name_count, index: int,
) -> Variable_Data {
	file := checker.type_checker.files[file_id]
	data := Variable_Data {
		storage = .Local,
	}
	if len(values) == name_count { data.value = Node_Ref{file_id, values[index]} }
	if !collection_has_attribute(file.ast, file.source, attributes, "static") { return data }
	data.storage = .Global
	if len(values) == name_count {
		data.initializer = Node_Ref{file_id, values[index]}
		data.initializer_view = view
	}
	return data
}

// Rejects unknown attribute names on a local declaration. A deferred_*
// attribute is returned for stamping; mutable declarations cannot carry one.
@(private = "file")
expression_local_attributes :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	element: syntax.Node_Index,
	name: string,
	ok: bool,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	declaration := syntax.node_payload(file.ast, node, syntax.Value_Decl)
	for attribute in syntax.node_list(file.ast, declaration.attributes) {
		for item in syntax.node_list(file.ast, syntax.node_payload(file.ast, attribute, syntax.Attribute).elems) {
			name_node := item
			if file.ast.nodes[item].kind == .Field_Value {
				name_node = syntax.node_payload(file.ast, item, syntax.Field_Value).field
			}
			text := expression_text(file, name_node)
			if !declaration_attribute_known(text) {
				expression_unsupported(
					checker,
					view,
					scope,
					item,
					fmt.aprintf("Unknown attribute element name '%s'", text, allocator = mem.dynamic_arena_allocator(&checker.arena)),
				) or_return
				return 0, "", false, nil
			}
			if deferred_attribute_kind(text) != .Absent {
				if element != 0 {
					expression_unsupported(checker, view, scope, item, "Previous usage of a 'deferred_*' attribute") or_return
					return 0, "", false, nil
				}
				element, name = item, text
			}
		}
	}
	return element, name, true, nil
}

// Links local procedure entities to their declaration so the deferred
// validator can find the attribute. Anything else carrying deferred_* is
// rejected here, as the official compiler does.
@(private = "file")
expression_stamp_local_procedures :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	element: syntax.Node_Index,
	name: string,
) -> Resolve_Error {
	if element == 0 { return nil }
	file := checker.type_checker.files[file_id]
	declaration := syntax.node_payload(file.ast, node, syntax.Value_Decl)
	scopes := checker.type_checker.resolver.scopes
	for name_node in syntax.node_list(file.ast, declaration.names) {
		if file.ast.nodes[name_node].kind != .Ident { continue }
		id := scope_lookup_current(scopes, scope, expression_text(file, name_node))
		if id == 0 { continue }
		// A predeclared `::` name stays a Constant aliasing the procedure entity.
		target := entity_get(scopes, id)
		if target.kind == .Constant && target.alias != 0 {
			id = target.alias
			target = entity_get(scopes, id)
		}
		if target == nil || target.kind != .Procedure {
			expression_unsupported(
				checker,
				view,
				scope,
				element,
				fmt.aprintf("Unknown attribute element name '%s'", name, allocator = mem.dynamic_arena_allocator(&checker.arena)),
			) or_return
			return nil
		}
		target.declaration = Node_Ref{file_id, node}
		if !(expression_deferred_attribute(checker, id) or_return) {
			procedure := &entity_get(scopes, id).data.(Procedure_Data)
			procedure.body_state = .Invalid
		}
	}
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
	if len(values) != 0 && collection_has_attribute(file.ast, file.source, declaration.attributes, "thread_local") {
		expression_unsupported(checker, view, scope, node, "A thread local variable declaration cannot have initialization values") or_return
		return nil
	}
	multi := len(values) == 1 && len(names) > 1
	deferred_element, deferred_name, attributes_ok := expression_local_attributes(checker, view, file_id, scope, node) or_return
	if !attributes_ok { return nil }
	if !declaration.is_mutable {
		expression_local_constant(checker, view, file_id, scope, node) or_return
		expression_stamp_local_procedures(checker, view, file_id, scope, node, deferred_element, deferred_name) or_return
		return nil
	}
	if deferred_element != 0 {
		expression_unsupported(
			checker,
			view,
			scope,
			deferred_element,
			fmt.aprintf("Unknown attribute element name '%s'", deferred_name, allocator = mem.dynamic_arena_allocator(&checker.arena)),
		) or_return
		return nil
	}
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
		if value.mode == .Type {
			expression_type_variable_failure(
				checker,
				view,
				scope,
				values[index],
				value.type,
				expression_text(file, names[index]),
				declaration.type == 0,
			) or_return
			variable_types[index] = types.TYPE_POISON
			continue
		}
		variable_types[index] = target
		if target != 0 { continue }
		#partial switch types.get(checker.type_checker.store, value.type).kind {
		case .Untyped_Integer:
			variable_types[index] = checker.default_integer
		case .Untyped_Bool:
			variable_types[index] = checker.boolean
		case .Untyped_Float, .Untyped_Rune, .Untyped_Complex, .Untyped_Quaternion, .Untyped_String:
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
				declaration = {file_id, name_node},
				kind = .Variable,
				scope = scope,
				state = .Resolved,
				type = variable_types[index],
				data = local_variable_data(checker, file_id, view, declaration.attributes, values, len(names), index),
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

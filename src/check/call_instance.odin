package check

import "base:runtime"
import "core:fmt"
import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
is_generic_procedure :: proc(checker: ^Expression_Checker, entity: Entity_Id) -> bool {
	procedure, is_procedure := entity_get(checker.type_checker.resolver.scopes, entity).data.(Procedure_Data)
	return is_procedure && procedure.generic
}

// An instance body has its own typed view, selected by its instance id.
@(private = "package")
expression_body_view :: proc(checker: ^Expression_Checker, procedure: Procedure_Data, file: File_Id) -> (view: View_Id, err: runtime.Allocator_Error) {
	outer_instance := checker.active_instance
	checker.active_instance = procedure.instance
	defer checker.active_instance = outer_instance
	return expression_file_view(checker, file)
}

// A generic callee has no value type, so it is named here instead of checked as a value.
@(private = "package")
expression_callee :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	callee: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	if file.ast.nodes[callee].kind == .Ident {
		entity, _ := scope_lookup(checker.type_checker.resolver.scopes, scope, expression_text(file, callee))
		if entity != 0 && is_generic_procedure(checker, entity) {
			return Expression_Info{scope = scope, mode = .Value, entity = entity, state = .Checked}, nil
		}
	}
	return check_expression(checker, view, scope, callee)
}

// Binds each `$T` parameter from its argument's type, then reuses or checks the instance for those types.
@(private = "package")
expression_generic_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	callee: Expression_Info,
	arguments: []syntax.Node_Index,
	spread: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	definition := callee.entity
	declaration := checker.type_checker.declarations[definition]
	definition_scope := entity_get(checker.type_checker.resolver.scopes, definition).scope
	if declaration.type.node == 0 { return expression_unsupported(checker, view, scope, node, "Generic_Call_Declaration") }
	file := checker.type_checker.files[declaration.type.file]
	signature := syntax.node_payload(file.ast, declaration.type.node, syntax.Proc_Type)
	params := syntax.node_payload(file.ast, signature.params, syntax.Field_List)
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	bindings: Poly_Bindings
	bindings.names.allocator = allocator
	bindings.types.allocator = allocator
	bindings.constants.allocator = allocator
	match := Poly_Match {
		checker         = checker,
		call_file       = file_id,
		call_node       = node,
		definition_file = declaration.type.file,
		scope           = definition_scope,
		bindings        = &bindings,
	}
	caller := checker.type_checker.files[file_id]
	names := declared_parameter_names(file, params, allocator) or_return
	variadic_index := procedure_variadic_index(file, declaration.type.node)
	if variadic_index >= 0 && variadic_index != len(names) - 1 {
		return expression_unsupported(checker, view, scope, node, "Generic_Call_Variadic_Not_Last")
	}
	if spread {
		spread_positional_count := call_positional_count(caller, arguments)
		if variadic_index < 0 { return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread") }
		if spread_positional_count > variadic_index + 1 { return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread_Arguments") }
		if spread_positional_count != variadic_index + 1 { return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread_Position") }
	}
	slots := make([]Call_Slot, len(names), allocator) or_return
	if reason := call_bind_arguments(caller, arguments, names, len(names), slots); reason != "" {
		return expression_unsupported(checker, view, scope, node, reason)
	}
	positional_count := call_positional_count(caller, arguments)
	if positional_count > len(names) && positional_count < len(arguments) {
		return expression_unsupported(checker, view, scope, node, "Generic_Call_Named_Variadic")
	}
	is_runtime := make([]bool, len(arguments), allocator) or_return
	for index in len(names) ..< positional_count {
		is_runtime[index] = true
	}
	parameter_index := 0
	runtime_arguments: [dynamic]syntax.Node_Index
	runtime_arguments.allocator = allocator
	deferred: [dynamic]Untyped_Pattern
	deferred.allocator = allocator
	for field_node in syntax.node_list(file.ast, params.list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		for name in syntax.node_list(file.ast, field.names) {
			slot := slots[parameter_index]
			parameter_index += 1
			if slot.value == 0 {
				if field.default_value == 0 || file.ast.nodes[name].kind == .Poly_Type {
					return expression_unsupported(checker, view, scope, node, "Generic_Call_Arguments")
				}
				continue
			}
			argument_node := slot.value
			if file.ast.nodes[name].kind == .Poly_Type && !is_type_param_field(file, field) {
				constant_type := type_expression(checker.type_checker, declaration.type.file, definition_scope, field.type, true) or_return
				if constant_type == types.TYPE_POISON { return expression_poison(scope), nil }
				argument := check_expression(checker, view, scope, argument_node, constant_type) or_return
				if argument.state == .Invalid { return expression_poison(scope), nil }
				if argument.mode != .Constant { return expression_unsupported(checker, view, scope, node, "Generic_Call_Constant_Parameter") }
				converted := expression_conversion(
					checker,
					view,
					scope,
					argument_node,
					Operand(Expression_Ref{view, argument_node}),
					argument,
					constant_type,
					.Assignment,
				) or_return
				if converted.state == .Invalid { return expression_poison(scope), nil }
				poly_name := expression_text(file, syntax.node_payload(file.ast, name, syntax.Poly_Type).type)
				bound := poly_bind(&bindings, poly_name, constant_type, converted.constant) or_return
				if !bound { return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Conflict") }
				continue
			}
			argument_hint: types.Type_Id
			if caller.ast.nodes[argument_node].kind == .Implicit_Selector_Expr && !poly_pattern_has_poly(file, field.type) {
				if field.type != 0 {
					argument_hint = type_expression(checker.type_checker, declaration.type.file, definition_scope, field.type, true) or_return
				} else {
					default_hint, _, hint_error := default_parameter_type(
						checker.type_checker,
						declaration.type.file,
						file,
						definition_scope,
						field.default_value,
					)
					if hint_error != nil { return {}, hint_error }
					argument_hint = default_hint
				}
			}
			argument := check_expression(checker, view, scope, argument_node, argument_hint) or_return
			if argument.state == .Invalid { return expression_poison(scope), nil }
			if file.ast.nodes[name].kind == .Poly_Type {
				if argument.mode != .Type { return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Parameter") }
				poly := syntax.node_payload(file.ast, name, syntax.Poly_Type)
				matched := poly_bind(&bindings, expression_text(file, poly.type), argument.type, 0) or_return
				if matched && file.ast.nodes[field.type].kind == .Typeid_Type {
					specialization := syntax.node_payload(file.ast, field.type, syntax.Typeid_Type).specialization
					if specialization != 0 { matched = poly_match_pattern(&match, specialization, argument.type) or_return }
				}
				if !matched { return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Conflict") }
				continue
			}
			is_runtime[slot.position] = true
			if spread && file.ast.nodes[field.type].kind == .Ellipsis {
				matched := poly_match_spread(&match, field.type, argument.type) or_return
				if !matched { return expression_unsupported(checker, view, scope, node, "Generic_Call_Spread_Type") }
				continue
			}
			if poly_untyped_deferred(file, spread, field.type, types.get(checker.type_checker.store, argument.type).kind) {
				append(&deferred, Untyped_Pattern{pattern = field.type, type = argument.type}) or_return
				continue
			}
			if !poly_pattern_has_poly(file, field.type) { continue }
			poly_argument := types.default_type_of_untyped(checker.type_checker.store, argument.type)
			matched := poly_match_pattern(&match, field.type, poly_argument) or_return
			if !matched { return expression_unsupported(checker, view, scope, node, "Generic_Call_Pattern") }
		}
	}
	deferred_matched := poly_bind_deferred(&match, deferred[:]) or_return
	if !deferred_matched { return expression_unsupported(checker, view, scope, node, "Generic_Call_Pattern") }
	for argument, index in arguments {
		if is_runtime[index] { append(&runtime_arguments, argument) or_return }
	}
	scopes := checker.type_checker.resolver.scopes
	for entity, id in scopes.entities {
		procedure, is_procedure := entity.data.(Procedure_Data)
		if !is_procedure ||
		   procedure.definition != definition ||
		   !same_elements(procedure.poly_arguments, bindings.types[:]) ||
		   !same_elements(procedure.poly_constants, bindings.constants[:]) { continue }
		return expression_instance_call(checker, view, file_id, scope, node, Entity_Id(id), runtime_arguments[:], spread)
	}
	return expression_new_instance(
		checker,
		view,
		file_id,
		scope,
		node,
		definition,
		declaration,
		bindings.names[:],
		bindings.types[:],
		bindings.constants[:],
		runtime_arguments[:],
		spread,
	)
}

// A `$T: typeid` parameter binds a type at compile time; it is not a runtime parameter.
@(private = "package")
is_type_param_field :: proc(file: ^File, field: syntax.Field) -> bool {
	if field.names.count == 0 || file.ast.nodes[field.type].kind != .Typeid_Type { return false }
	return file.ast.nodes[syntax.node_list(file.ast, field.names)[0]].kind == .Poly_Type
}

// A `$T` or `$N` name is bound by the call, so the instance signature leaves the parameter out.
@(private = "package")
is_poly_name_field :: proc(file: ^File, field: syntax.Field) -> bool {
	return field.names.count > 0 && file.ast.nodes[syntax.node_list(file.ast, field.names)[0]].kind == .Poly_Type
}

// A spread's slice matches the `..P` parameter's element pattern P. A bare name that the definition does not declare is one of its polymorphic names.
@(private = "package")
poly_match_spread :: proc(match: ^Poly_Match, variadic: syntax.Node_Index, slice: types.Type_Id) -> (matched: bool, err: Resolve_Error) {
	store := match.checker.type_checker.store
	file := match.checker.type_checker.files[match.definition_file]
	descriptor := types.get(store, underlying_type(store, slice))
	if descriptor.kind != .Slice { return false, nil }
	pattern := syntax.node_payload(file.ast, variadic, syntax.Ellipsis).expr
	if file.ast.nodes[pattern].kind == .Ident {
		name := expression_text(file, pattern)
		if entity, _ := scope_lookup(match.checker.type_checker.resolver.scopes, match.scope, name); entity == 0 {
			return poly_bind(match.bindings, name, descriptor.elem, 0)
		}
	}
	return poly_match_pattern(match, pattern, descriptor.elem)
}

// An untyped argument under a spread binds a bare polymorphic name only after the typed arguments, as official does.
@(private = "package")
Untyped_Pattern :: struct {
	pattern: syntax.Node_Index,
	type:    types.Type_Id,
}

@(private = "package")
poly_untyped_deferred :: proc(file: ^File, spread: bool, pattern: syntax.Node_Index, kind: types.Kind) -> bool {
	if !spread || file.ast.nodes[pattern].kind != .Poly_Type || !conversion_untyped(kind) { return false }
	return syntax.node_payload(file.ast, pattern, syntax.Poly_Type).specialization == 0
}

// Binds each deferred untyped argument's name to its default type, unless a typed argument bound the name first.
@(private = "package")
poly_bind_deferred :: proc(match: ^Poly_Match, deferred: []Untyped_Pattern) -> (matched: bool, err: Resolve_Error) {
	store := match.checker.type_checker.store
	file := match.checker.type_checker.files[match.definition_file]
	for entry in deferred {
		name := expression_text(file, syntax.node_payload(file.ast, entry.pattern, syntax.Poly_Type).type)
		bound := false
		for bound_name in match.bindings.names { bound ||= bound_name == name }
		if bound { continue }
		matched = poly_match_pattern(match, entry.pattern, types.default_type_of_untyped(store, entry.type)) or_return
		if !matched { return false, nil }
	}
	return true, nil
}

@(private = "file")
same_elements :: proc(left, right: []$T) -> bool {
	if len(left) != len(right) { return false }
	for type, index in left {
		if type != right[index] { return false }
	}
	return true
}

@(private = "file")
expression_new_instance :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	definition: Entity_Id,
	declaration: Collected_Declaration,
	poly_names: []string,
	poly_types: []types.Type_Id,
	poly_constants: []Const_Id,
	arguments: []syntax.Node_Index,
	spread: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	resolver := checker.type_checker.resolver
	scopes := resolver.scopes
	definition_entity := entity_get(scopes, definition)
	definition_procedure := definition_entity.data.(Procedure_Data)
	definition_package_id := definition_entity.package_id
	definition_name := definition_entity.name
	definition_declaration := definition_entity.declaration
	arena := mem.dynamic_arena_allocator(&checker.arena)
	type_scope, scope_error := scope_create(scopes, definition_entity.scope, .Block, definition)
	if scope_error != nil { return {}, binding_resolve_error(scope_error) }
	for name, index in poly_names {
		bound_entity := Entity {
			name       = name,
			kind       = .Type_Name,
			scope      = type_scope,
			package_id = definition_package_id,
			state      = .Resolved,
			type       = poly_types[index],
		}
		if poly_constants[index] != 0 {
			bound_entity.kind, bound_entity.constant = .Constant, poly_constants[index]
		}
		bound, bound_error := entity_create(scopes, bound_entity)
		if bound_error != nil { return {}, binding_resolve_error(bound_error) }
		_, insert_error := scope_insert(scopes, type_scope, bound)
		if insert_error != nil { return {}, binding_resolve_error(insert_error) }
	}
	name := fmt.aprintf("%s[%v|%v]", definition_name, poly_types, poly_constants, allocator = arena)
	instance, create_error := entity_create(
		scopes,
		Entity {
			name = name,
			kind = .Procedure,
			scope = type_scope,
			package_id = definition_package_id,
			declaration = definition_declaration,
			state = .Resolving,
			data = Procedure_Data {
				definition = definition,
				poly_arguments = poly_types,
				poly_constants = poly_constants,
				body = definition_procedure.body,
				where_clauses = definition_procedure.where_clauses,
				body_state = .Unchecked,
			},
		},
	)
	if create_error != nil { return {}, binding_resolve_error(create_error) }
	procedure := &entity_get(scopes, instance).data.(Procedure_Data)
	procedure.instance = Instance_Id(instance)
	outer_instantiating := checker.type_checker.instantiating
	checker.type_checker.instantiating = true
	signature, signature_error := type_expression(checker.type_checker, declaration.type.file, type_scope, declaration.type.node, true)
	checker.type_checker.instantiating = outer_instantiating
	if signature_error != nil { return {}, signature_error }
	if signature == types.TYPE_POISON { return expression_poison(scope), nil }
	descriptor := types.get(checker.type_checker.store, signature)
	entity := entity_get(scopes, instance)
	entity.type = signature
	procedure = &entity.data.(Procedure_Data)
	procedure.signature = signature
	procedure.convention = descriptor.convention
	procedure.variadic_index = procedure_variadic_index(checker.type_checker.files[declaration.type.file], declaration.type.node)
	outer_instance := checker.active_instance
	checker.active_instance = Instance_Id(instance)
	valid, body_error := expression_procedure_body(checker, resolver, instance, declaration.type)
	checker.active_instance = outer_instance
	if body_error != nil { return {}, body_error }
	entity_get(scopes, instance).state = .Resolved if valid else .Invalid
	if !valid || entity_get(scopes, instance).data.(Procedure_Data).body_state != .Complete {
		if !valid && definition_procedure.where_clauses.count != 0 {
			return expression_failure(checker, view, scope, node, .Invalid_Operand, "at caller location")
		}
		return expression_poison(scope), nil
	}
	return expression_instance_call(checker, view, file_id, scope, node, instance, arguments, spread)
}

@(private = "file")
expression_instance_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	instance: Entity_Id,
	arguments: []syntax.Node_Index,
	spread: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	entity := entity_get(checker.type_checker.resolver.scopes, instance)
	procedure := entity.data.(Procedure_Data)
	if entity.state != .Resolved {
		if entity.state == .Invalid &&
		   procedure.where_clauses.count != 0 { return expression_failure(checker, view, scope, node, .Invalid_Operand, "at caller location") }
		return expression_poison(scope), nil
	}
	if procedure.body_state == .Invalid {
		return expression_poison(scope), nil
	}
	callee := Expression_Info {
		scope  = scope,
		mode   = .Value,
		type   = entity.type,
		entity = instance,
		state  = .Checked,
	}
	return expression_call(checker, view, file_id, scope, node, callee, arguments, spread)
}

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
	if spread { return expression_unsupported(checker, view, scope, node, "Generic_Call_Spread") }
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
	argument_index := 0
	runtime_arguments: [dynamic]syntax.Node_Index
	runtime_arguments.allocator = allocator
	for field_node in syntax.node_list(file.ast, params.list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		for name in syntax.node_list(file.ast, field.names) {
			if argument_index >= len(arguments) {
				if field.default_value == 0 || file.ast.nodes[name].kind == .Poly_Type {
					return expression_unsupported(checker, view, scope, node, "Generic_Call_Arguments")
				}
				continue
			}
			argument_node := arguments[argument_index]
			argument_index += 1
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
			caller := checker.type_checker.files[file_id]
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
			append(&runtime_arguments, argument_node) or_return
			if !poly_pattern_has_poly(file, field.type) { continue }
			poly_argument := types.default_type_of_untyped(checker.type_checker.store, argument.type)
			matched := poly_match_pattern(&match, field.type, poly_argument) or_return
			if !matched { return expression_unsupported(checker, view, scope, node, "Generic_Call_Pattern") }
		}
	}
	for remaining in arguments[argument_index:] {
		append(&runtime_arguments, remaining) or_return
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
	arena := mem.dynamic_arena_allocator(&checker.arena)
	type_scope, scope_error := scope_create(scopes, definition_entity.scope, .Block, definition)
	if scope_error != nil { return {}, binding_resolve_error(scope_error) }
	for name, index in poly_names {
		bound_entity := Entity {
			name       = name,
			kind       = .Type_Name,
			scope      = type_scope,
			package_id = definition_entity.package_id,
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
	name := fmt.aprintf("%s[%v|%v]", definition_entity.name, poly_types, poly_constants, allocator = arena)
	instance, create_error := entity_create(
		scopes,
		Entity {
			name = name,
			kind = .Procedure,
			scope = type_scope,
			package_id = definition_entity.package_id,
			declaration = definition_entity.declaration,
			state = .Resolving,
			data = Procedure_Data {
				definition = definition,
				poly_arguments = poly_types,
				poly_constants = poly_constants,
				body = definition_procedure.body,
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
	outer_instance := checker.active_instance
	checker.active_instance = Instance_Id(instance)
	valid, body_error := expression_procedure_body(checker, resolver, instance, declaration.type)
	checker.active_instance = outer_instance
	if body_error != nil { return {}, body_error }
	entity_get(scopes, instance).state = .Resolved
	if !valid || entity_get(scopes, instance).data.(Procedure_Data).body_state != .Complete { return expression_poison(scope), nil }
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
	if entity.state != .Resolved { return expression_poison(scope), nil }
	callee := Expression_Info {
		scope  = scope,
		mode   = .Value,
		type   = entity.type,
		entity = instance,
		state  = .Checked,
	}
	return expression_call(checker, view, file_id, scope, node, callee, arguments, spread)
}

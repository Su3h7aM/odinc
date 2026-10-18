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
	if declaration.type.node == 0 { return expression_unsupported(checker, view, scope, node, "Generic_Call_Declaration") }
	file := checker.type_checker.files[declaration.type.file]
	signature := syntax.node_payload(file.ast, declaration.type.node, syntax.Proc_Type)
	params := syntax.node_payload(file.ast, signature.params, syntax.Field_List)
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	poly_names: [dynamic]string
	poly_types: [dynamic]types.Type_Id
	poly_names.allocator = allocator
	poly_types.allocator = allocator
	argument_index := 0
	runtime_arguments: [dynamic]syntax.Node_Index
	runtime_arguments.allocator = allocator
	for field_node in syntax.node_list(file.ast, params.list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		for name in syntax.node_list(file.ast, field.names) {
			if argument_index >= len(arguments) {
				return expression_unsupported(checker, view, scope, node, "Generic_Call_Arguments")
			}
			argument_node := arguments[argument_index]
			argument_index += 1
			argument := check_expression(checker, view, scope, argument_node) or_return
			if argument.state == .Invalid { return expression_poison(scope), nil }
			poly_node: syntax.Node_Index
			bound: types.Type_Id
			if file.ast.nodes[name].kind == .Poly_Type {
				if !is_type_param_field(file, field) ||
				   argument.mode != .Type { return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Parameter") }
				poly_node = name
				bound = argument.type
			} else {
				append(&runtime_arguments, argument_node) or_return
				if file.ast.nodes[field.type].kind != .Poly_Type { continue }
				poly_node = field.type
				bound = types.default_type_of_untyped(checker.type_checker.store, argument.type)
			}
			poly := syntax.node_payload(file.ast, poly_node, syntax.Poly_Type)
			if poly.specialization != 0 { return expression_unsupported(checker, view, scope, node, "Generic_Call_Specialization") }
			poly_name := expression_text(file, poly.type)
			slot := slice_index(poly_names[:], poly_name)
			if slot < 0 {
				append(&poly_names, poly_name) or_return
				append(&poly_types, bound) or_return
			} else if poly_types[slot] != bound {
				return expression_unsupported(checker, view, scope, node, "Generic_Call_Type_Conflict")
			}
		}
	}
	for remaining in arguments[argument_index:] {
		append(&runtime_arguments, remaining) or_return
	}
	scopes := checker.type_checker.resolver.scopes
	for entity, id in scopes.entities {
		procedure, is_procedure := entity.data.(Procedure_Data)
		if !is_procedure || procedure.definition != definition || !same_types(procedure.poly_arguments, poly_types[:]) { continue }
		return expression_instance_call(checker, view, file_id, scope, node, Entity_Id(id), runtime_arguments[:], spread)
	}
	return expression_new_instance(checker, view, file_id, scope, node, definition, declaration, poly_names[:], poly_types[:], runtime_arguments[:], spread)
}

// A `$T: typeid` parameter binds a type at compile time; it is not a runtime parameter.
@(private = "package")
is_type_param_field :: proc(file: ^File, field: syntax.Field) -> bool {
	if field.names.count == 0 || file.ast.nodes[field.type].kind != .Typeid_Type { return false }
	return file.ast.nodes[syntax.node_list(file.ast, field.names)[0]].kind == .Poly_Type
}

@(private = "file")
slice_index :: proc(names: []string, name: string) -> int {
	for existing, index in names {
		if existing == name { return index }
	}
	return -1
}

@(private = "file")
same_types :: proc(left, right: []types.Type_Id) -> bool {
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
		bound, bound_error := entity_create(
			scopes,
			Entity{name = name, kind = .Type_Name, scope = type_scope, package_id = definition_entity.package_id, state = .Resolved, type = poly_types[index]},
		)
		if bound_error != nil { return {}, binding_resolve_error(bound_error) }
		_, insert_error := scope_insert(scopes, type_scope, bound)
		if insert_error != nil { return {}, binding_resolve_error(insert_error) }
	}
	name := fmt.aprintf("%s[%v]", definition_entity.name, poly_types, allocator = arena)
	instance, create_error := entity_create(
		scopes,
		Entity {
			name = name,
			kind = .Procedure,
			scope = type_scope,
			package_id = definition_entity.package_id,
			declaration = definition_entity.declaration,
			state = .Resolving,
			data = Procedure_Data{definition = definition, poly_arguments = poly_types, body = definition_procedure.body, body_state = .Unchecked},
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

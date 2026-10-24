package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// A generic procedure used as a value takes the instance whose parameters are the target procedure type's, as the
// official check_polymorphic_procedure_assignment does. The row is unchanged when the target is not a procedure type
// or its parameters do not bind every name, or the instance does not have the target type.
@(private = "package")
expression_generic_value :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	generic: Expression_Info,
	target: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	target_type := types.get(store, types.resolve_named(store, target))
	if target_type.kind != .Procedure { return generic, nil }
	definition := generic.entity
	declaration := checker.type_checker.declarations[definition]
	if declaration.type.node == 0 { return generic, nil }
	file := checker.type_checker.files[declaration.type.file]
	signature := syntax.node_payload(file.ast, declaration.type.node, syntax.Proc_Type)
	if signature.params == 0 { return generic, nil }
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
		scope           = entity_get(checker.type_checker.resolver.scopes, definition).scope,
		bindings        = &bindings,
	}
	position := 0
	for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, signature.params, syntax.Field_List).list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		if is_poly_name_field(file, field) || field.type == 0 || file.ast.nodes[field.type].kind == .Ellipsis { return generic, nil }
		for _ in 0 ..< max(1, int(field.names.count)) {
			if position >= len(target_type.params) { return generic, nil }
			if poly_pattern_has_poly(file, field.type) {
				if matched := poly_match_pattern(&match, field.type, target_type.params[position]) or_return; !matched { return generic, nil }
			}
			position += 1
		}
	}
	if position != len(target_type.params) { return generic, nil }

	scopes := checker.type_checker.resolver.scopes
	key := instance_index_key(store, definition, bindings.types[:], bindings.constants[:])
	instance: Entity_Id
	for id in instance_index_candidates(&checker.type_checker.resolver.instances, key) {
		procedure := &entity_get(scopes, id).data.(Procedure_Data)
		if procedure.definition == definition &&
		   same_type_arguments(store, procedure.poly_arguments, bindings.types[:]) &&
		   same_elements(procedure.poly_constants, bindings.constants[:]) {
			instance = id
			break
		}
	}
	if instance == 0 {
		created: bool
		failure: Expression_Info
		instance, failure, created = expression_create_instance(
			checker,
			view,
			scope,
			node,
			definition,
			declaration,
			bindings.names[:],
			bindings.types[:],
			bindings.constants[:],
		) or_return
		if !created { return failure, nil }
	}
	instance_type := entity_get(scopes, instance).type
	if !types.are_identical(store, instance_type, types.resolve_named(store, target)) { return generic, nil }
	return Expression_Info{type = instance_type, mode = .Value, entity = instance, scope = scope, state = .Checked}, nil
}

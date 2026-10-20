package check

import "core:fmt"
import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_procedure_literal :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	name_node: syntax.Node_Index = 0,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	literal := syntax.node_payload(file.ast, node, syntax.Proc_Lit)
	if literal.body == 0 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	generic := syntax.node_payload(file.ast, literal.type, syntax.Proc_Type).generic
	signature: types.Type_Id
	procedure := Procedure_Data {
		source_name    = "(anonymous-procedure)",
		generic        = generic,
		variadic_index = procedure_variadic_index(file, literal.type),
		body           = {file_id, literal.body},
		where_clauses  = literal.where_clauses,
		instance       = checker.active_instance,
	}
	if name_node != 0 { procedure.source_name = expression_text(file, name_node) }
	if !generic {
		signature = type_expression(checker.type_checker, file_id, scope, literal.type, true) or_return
		if signature == types.TYPE_POISON { return expression_poison(scope), nil }
		procedure.signature = signature
		procedure.convention = types.get(checker.type_checker.store, signature).convention
	}
	scopes := checker.type_checker.resolver.scopes
	name := fmt.aprintf("__literal_%d_%d_%d", file_id, node, len(scopes.entities), allocator = mem.dynamic_arena_allocator(&checker.arena))
	id, create_error := entity_create(
		scopes,
		Entity {
			name = name,
			kind = .Procedure,
			flags = {.Private_File},
			scope = scope,
			package_id = file.package_id,
			state = .Resolved,
			type = signature,
			data = procedure,
		},
	)
	if create_error != nil { return {}, binding_resolve_error(create_error) }
	if name_node != 0 {
		binding_name := expression_text(file, name_node)
		if scope_lookup_current(scopes, scope, binding_name) != 0 {
			return expression_unsupported(checker, view, scope, name_node, "Local_Constant_Duplicate")
		}
		scope_get(scopes, scope).lookup[binding_name] = id
	}
	// Bodies wait for an empty resolver stack like expression_procedure_declaration, so recursion through literal name bindings is not a declaration cycle. The declaration records the literal's signature node for expression_procedure_body_declaration.
	resolver := checker.type_checker.resolver
	checker.type_checker.declarations[id] = Collected_Declaration {
		entity     = id,
		identifier = {file_id, node},
		type       = {file_id, literal.type},
	}
	if !generic {
		_, defer_error := append(&resolver.pending_bodies, id)
		if defer_error != nil { return {}, defer_error }
	}
	info = Expression_Info {
		type   = signature,
		mode   = .Value,
		entity = id,
		scope  = scope,
		state  = .Checked,
	}
	expression_store(checker, view, node, info)
	if name_node != 0 { expression_store(checker, view, name_node, info) }
	return info, nil
}

@(private = "package")
expression_captures_local :: proc(scopes: ^Scope_Store, scope: Scope_Id, binding: ^Entity) -> bool {
	if binding.kind != .Variable { return false }
	data, is_variable := binding.data.(Variable_Data)
	if !is_variable || data.storage != .Local { return false }
	procedure_scope := scope
	for procedure_scope != 0 && scope_get(scopes, procedure_scope).kind != .Procedure {
		procedure_scope = scope_get(scopes, procedure_scope).parent
	}
	if procedure_scope == 0 { return false }
	for binding_scope := binding.scope; binding_scope != 0; binding_scope = scope_get(scopes, binding_scope).parent {
		if binding_scope == procedure_scope { return false }
	}
	return true
}

package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// Named results are zero-initialized locals of the procedure scope. Official: check_type.cpp:4092 (has_named_results),
// check_stmt.cpp:2763-2778 (a bare return is valid when results are named).
@(private = "package")
expression_result_bindings :: proc(
	checker: ^Expression_Checker,
	resolver: ^Resolver,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	results: syntax.Node_Index,
	result_types: []types.Type_Id,
) -> (
	named: []Entity_Id,
	defaults: []Default_Argument,
	valid: bool,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	fields := syntax.node_list(file.ast, syntax.node_payload(file.ast, results, syntax.Field_List).list)
	if len(fields) == 0 { return nil, nil, true, nil }
	first_names := syntax.node_list(file.ast, syntax.node_payload(file.ast, fields[0], syntax.Field).names)
	if len(first_names) == 0 || expression_text(file, first_names[0]) == "" { return nil, nil, true, nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	entities: [dynamic]Entity_Id
	entities.allocator = allocator
	default_nodes: [dynamic]syntax.Node_Index
	default_nodes.allocator = allocator
	for field_node in fields {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		for name_node in syntax.node_list(file.ast, field.names) {
			index := len(entities)
			if index >= len(result_types) || expression_text(file, name_node) == "" {
				expression_unsupported(checker, view, scope, name_node, "Result_Name") or_return
				return nil, nil, false, nil
			}
			result, create_error := entity_create(
				resolver.scopes,
				Entity {
					name = expression_text(file, name_node),
					kind = .Variable,
					scope = scope,
					state = .Resolved,
					type = result_types[index],
					data = Variable_Data{storage = .Local},
				},
			)
			if create_error != nil { return nil, nil, false, binding_resolve_error(create_error) }
			previous, insert_error := scope_insert(resolver.scopes, scope, result)
			if insert_error != nil { return nil, nil, false, binding_resolve_error(insert_error) }
			if previous != 0 {
				expression_unsupported(checker, view, scope, name_node, "Result_Duplicate") or_return
				return nil, nil, false, nil
			}
			expression_store(
				checker,
				view,
				name_node,
				Expression_Info{type = result_types[index], mode = .Variable, entity = result, scope = scope, state = .Checked},
			)
			append(&entities, result) or_return
			append(&default_nodes, field.default_value) or_return
		}
	}
	// Defaults are checked once every result is declared, so a reference to any entity of this scope is seen below.
	defaults = make([]Default_Argument, len(entities), allocator) or_return
	for default_node, index in default_nodes {
		if default_node == 0 { continue }
		argument := expression_default_argument(checker, view, scope, default_node, result_types[index]) or_return
		#partial switch argument.kind {
		case .Constant:
		case .Invalid:
			return nil, nil, false, nil
		case .Value:
			info := check_expression(checker, view, scope, default_node) or_return
			if info.entity != 0 && entity_get(resolver.scopes, info.entity).scope == scope {
				expression_unsupported(checker, view, scope, default_node, "Default_Parameter_Reference") or_return
				return nil, nil, false, nil
			}
		case:
			expression_unsupported(checker, view, scope, default_node, "Default_Result_Kind") or_return
			return nil, nil, false, nil
		}
		defaults[index] = argument
	}
	return entities[:], defaults, true, nil
}

// Official rejects a singular deferred assignment, not assignments nested in control flow.
@(private = "package")
assigns_named_result_in_defer :: proc(checker: ^Expression_Checker, destination: Expression_Info, operator: syntax.Token_Kind) -> bool {
	if operator != .Eq || checker.defer_depth == 0 || destination.entity == 0 { return false }
	for result in checker.named_results {
		if result == destination.entity { return true }
	}
	return false
}

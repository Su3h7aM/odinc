package check

import "base:runtime"

// Rebuilds the symbol and procedure tables from entity states; call after the last checking phase.
expression_checker_publish_procedures :: proc(checker: ^Expression_Checker, program: ^Checked_Program) -> runtime.Allocator_Error {
	scopes := checker.type_checker.resolver.scopes
	clear(&checker.symbols)
	clear(&checker.entity_symbols)
	clear(&checker.procedures)
	append(&checker.symbols, Symbol{}) or_return
	for _ in scopes.entities {
		append(&checker.entity_symbols, 0) or_return
	}
	for entity, id in scopes.entities {
		if entity.kind != .Procedure { continue }
		procedure, is_procedure := entity.data.(Procedure_Data)
		if !is_procedure || procedure.body.node == 0 || procedure.body_state != .Complete || entity.state != .Resolved { continue }
		symbol := Symbol_Id(len(checker.symbols))
		name := symbol_name(checker, program, entity) or_return
		linkage := symbol_linkage(checker, entity) or_return
		append(&checker.symbols, Symbol{entity = Entity_Id(id), kind = .Procedure, name = name, type = procedure.signature, linkage = linkage}) or_return
		checker.entity_symbols[id] = symbol
		view := expression_body_view(checker, procedure, procedure.body.file) or_return
		span := checker.type_checker.files[procedure.body.file].ast.nodes[procedure.body.node]
		append(
			&checker.procedures,
			Checked_Procedure {
				entity = Entity_Id(id),
				symbol = symbol,
				signature = procedure.signature,
				body = procedure.body,
				view = view,
				source = {procedure.body.file, span.start, span.end},
				parameters = procedure.parameters,
				results = procedure.results,
				defers = procedure.defers,
				convention = procedure.convention,
			},
		) or_return
	}
	if collection := checker.type_checker.collection; collection != nil && collection.runtime_scope != 0 {
		entity := scope_lookup_current(scopes, collection.runtime_scope, "__init_context")
		if entity != 0 && checker.entity_symbols[entity] != 0 { program.runtime.init_context = entity }
	}
	expression_checker_publish_globals(checker, program) or_return
	expression_checker_publish_type_info(checker, program) or_return
	expression_checker_publish_map_cell_info(checker, program) or_return
	expression_checker_publish_map_info(checker, program) or_return
	expression_checker_publish_comparison_procedures(checker) or_return
	program.symbol_table = checker.symbols[:]
	program.entity_symbols = checker.entity_symbols[:]
	program.procedure_list = checker.procedures[:]
	expression_checker_publish(checker, program)
	return nil
}

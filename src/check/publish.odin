package check

// Rebuilds the symbol and procedure tables from entity states; call after the last checking phase.
expression_checker_publish_procedures :: proc(checker: ^Expression_Checker, program: ^Checked_Program) -> Resolve_Error {
	expression_resolve_bounds_helpers(checker) or_return
	check_nominal_layouts(checker.type_checker) or_return
	expression_backfill_deferred_calls(checker)
	expression_report_deferred_sites(checker) or_return
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
		target_features, microarch, _ := procedure_effective_features(checker, Entity_Id(id))
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
				result_defaults = procedure.result_defaults,
				defers = procedure.defers,
				convention = procedure.convention,
				target_features = target_features,
				microarch = microarch,
				attributes = entity_get(scopes, Entity_Id(id)).attributes,
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
	expression_checker_publish_type_hashers(checker) or_return
	program.symbol_table = checker.symbols[:]
	program.entity_symbols = checker.entity_symbols[:]
	program.procedure_list = checker.procedures[:]
	expression_checker_publish(checker, program)
	return nil
}

// Flags every call to a deferred-annotated procedure with its deferred
// target, so lowering finds the call-site defer without re-resolving.
// Call plans are built without it because calls check before bodies do.
@(private = "package")
expression_backfill_deferred_calls :: proc(checker: ^Expression_Checker) {
	scopes := checker.type_checker.resolver.scopes
	for _, index in checker.plans {
		call, is_call := checker.plans[index].(Call_Plan)
		if !is_call || call.entity == 0 || call.deferred != 0 { continue }
		target := procedure_deferred_target(scopes, call.entity)
		if target == 0 { continue }
		checker.plans[index] = Plan(
			Call_Plan {
				callee = call.callee,
				entity = call.entity,
				instance = call.instance,
				arguments = call.arguments,
				results = call.results,
				context_plan = call.context_plan,
				variadic = call.variadic,
				deferred = target,
			},
		)
	}
}

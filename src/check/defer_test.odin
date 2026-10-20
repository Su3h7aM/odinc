package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(private = "package")
check_procedure_source :: proc(
	t: ^testing.T,
	source: []byte,
	expected_kind := Expression_Diagnostic_Kind.None,
	expected_reason := "",
	diagnostic_count := -1,
	procedure_name := "",
	intrinsic_names: []string = nil,
	package_kind: Package_Kind = .User,
	type_diagnostic_count := -1,
) -> (
	procedure: Procedure_Data,
	ok: bool,
) {
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expectf(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0, "%v", parser.errors) { return {}, false }
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return {}, false }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return {}, false }
	defer scope_store_destroy(&scopes)
	universe, universe_error := scope_create(&scopes, 0, .Universal)
	package_scope, package_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, universe_error == nil && package_error == nil && file_error == nil) { return {}, false }
	for value in ([2]bool{false, true}) {
		constant, constant_error := constant_pool_intern_bool(&pool, value, types.TYPE_UNTYPED_BOOL)
		if !testing.expect(t, constant_error == nil) { return {}, false }
		name := "true" if value else "false"
		entity, create_error := entity_create(
			&scopes,
			Entity{name = name, kind = .Constant, scope = universe, state = .Resolved, type = types.TYPE_UNTYPED_BOOL, constant = constant},
		)
		_, insert_error := scope_insert(&scopes, universe, entity)
		if !testing.expect(t, create_error == nil && insert_error == nil) { return {}, false }
	}
	if !testing.expect(t, bind_builtin_types(&scopes, universe, seed_builtin_types(&store)) == nil) { return {}, false }
	builtin_error := bind_universe_builtins(&scopes, universe)
	if !testing.expect(t, builtin_error == nil) { return {}, false }
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	if !testing.expect(t, collect_file(&collection, &file, 1, {}) == nil && len(collection.diagnostics) == 0) { return {}, false }
	checker: Expression_Checker
	resolver: Resolver
	resolver_init(&resolver, &scopes, expression_declaration, &checker, context.allocator)
	defer resolver_destroy(&resolver)
	type_checker: Type_Checker
	type_checker_init(&type_checker, &resolver, &collection, &store, []^File{nil, &file}, expression_integer_evaluator, &checker, context.allocator)
	defer type_checker_destroy(&type_checker)
	if !testing.expect(
		t,
		expression_checker_init(&checker, &type_checker, &pool, {uintptr = word, layout = types.DEFAULT_LAYOUT}, integer, boolean, context.allocator) == nil,
	) { return {}, false }
	defer expression_checker_destroy(&checker)
	checker.packages = []Package{{}, {kind = package_kind, scope = package_scope}}
	for name in intrinsic_names {
		builtin, failure := expression_builtin_id(&checker, intrinsic_builtin_kind(name))
		id, creation := entity_create(&scopes, Entity{name = name, kind = .Builtin, scope = universe, state = .Resolved, data = builtin})
		_, insertion := scope_insert(&scopes, universe, id)
		if !testing.expect(t, failure == nil && creation == nil && insertion == nil) { return {}, false }
	}
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		if expected_kind == .None &&
		   !testing.expectf(
				   t,
				   err == nil && (state == .Resolved || type_diagnostic_count > 0),
				   "%v %v %v",
				   state,
				   err,
				   checker.diagnostics,
			   ) { return {}, false }
	}
	if expected_kind != .None {
		reported := false
		for diagnostic in checker.diagnostics { reported ||= diagnostic.kind == expected_kind && diagnostic.reason == expected_reason }
		if !testing.expectf(t, reported, "expected %v %q, got %v", expected_kind, expected_reason, checker.diagnostics) { return {}, false }
	}
	if diagnostic_count >= 0 &&
	   !testing.expectf(t, len(checker.diagnostics) == diagnostic_count, "expected %d diagnostics, got %v", diagnostic_count, checker.diagnostics) {
		return {}, false
	}
	if type_diagnostic_count >= 0 &&
	   !testing.expectf(
			   t,
			   len(type_checker.diagnostics) == type_diagnostic_count,
			   "expected %d type diagnostics, got %v",
			   type_diagnostic_count,
			   type_checker.diagnostics,
		   ) {
		return {}, false
	}
	procedure_entity := scope_lookup_current(&scopes, package_scope, procedure_name if procedure_name != "" else "main")
	if procedure_name != "" { procedure_entity = scope_lookup_current(&scopes, package_scope, procedure_name) }
	if !testing.expectf(t, procedure_entity != 0, "no procedure named %q", procedure_name if procedure_name != "" else "main") { return {}, false }
	main_procedure, is_procedure := entity_get(&scopes, procedure_entity).data.(Procedure_Data)
	if !testing.expectf(t, is_procedure, "main has no procedure data, diagnostics %v", checker.diagnostics) { return {}, false }
	return main_procedure, true
}

@(test)
defer_registers_checked_body_and_rejects_return :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	value: u8
	defer value = 7
}
`)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
	testing.expect_value(t, len(procedure.defers), 1)

	invalid := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	defer { return }
}
`)
	rejected, rejected_ok := check_procedure_source(t, invalid)
	if !rejected_ok { return }
	testing.expect(t, rejected.body_state == .Invalid)
}


@(test)
assert_directive_checks_constant_boolean :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	#assert(1 == 1)
}
`)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

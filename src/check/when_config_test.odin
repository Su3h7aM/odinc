package check

import "core:testing"
import "oc:syntax"
import "oc:types"

// The runtime's `ODIN_CODEPAGE_MAGIC :: ODIN_OS == .Windows && #config(ODIN_CODEPAGE_MAGIC, !ODIN_BEDROCK)`
// names itself as the #config key while its condition folds the OS comparison against the config default.
@(test)
when_condition_with_config_default_and_os_comparison_folds :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
MAGIC :: ODIN_OS == .Windows && #config(MAGIC, !ODIN_BEDROCK)
when MAGIC {
	IS_MAGIC :: true
}
`)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expect(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0) { return }

	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return }
	defer scope_store_destroy(&scopes)
	universe, _ := scope_create(&scopes, 0, .Universal)
	if !testing.expect(t, bind_universe_constants(&scopes, universe, &pool)) { return }
	package_scope, _ := scope_create(&scopes, universe, .Package)
	file_scope, _ := scope_create(&scopes, package_scope, .File)

	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	collection.runtime_scope = package_scope
	if !testing.expect(t, collect_file(&collection, &file, 1, {file_order = 0}) == nil) { return }

	checker: Expression_Checker
	resolver: Resolver
	resolver_init(&resolver, &scopes, expression_declaration, &checker, context.allocator)
	defer resolver_destroy(&resolver)
	type_checker: Type_Checker
	files := []^File{nil, &file}
	type_checker_init(&type_checker, &resolver, &collection, &store, files, expression_integer_evaluator, &checker, context.allocator)
	defer type_checker_destroy(&type_checker)
	if !testing.expect(t, bind_universe_build_context(&type_checker, universe, &pool, DEFAULT_BUILD_CONFIGURATION)) { return }
	if !testing.expect(
		t,
		expression_checker_init(&checker, &type_checker, &pool, {uintptr = word, layout = types.DEFAULT_LAYOUT}, integer, boolean, context.allocator) == nil,
	) { return }
	defer expression_checker_destroy(&checker)

	for declaration in collection.declarations {
		state, resolve_error := resolve_entity(&resolver, declaration.entity)
		if !testing.expectf(
			t,
			resolve_error == nil && state == .Resolved,
			"%s %v %v",
			entity_get(&scopes, declaration.entity).name,
			state,
			resolve_error,
		) { return }
	}

	for index := 0; index < len(collection.pending); index += 1 {
		pending := collection.pending[index]
		if pending.handled || pending.kind != .When { continue }
		statement := syntax.node_payload(&ast, pending.declaration.node, syntax.When_Stmt)
		condition, evaluated, evaluate_error := type_checker.evaluate_boolean(
			&type_checker,
			file.scope,
			pending.declaration.file,
			statement.cond,
			type_checker.user_data,
		)
		if !testing.expectf(t, evaluate_error == nil && evaluated, "%v %v", evaluate_error, evaluated) { return }
		if !testing.expectf(t, condition == false, "expected the Linux arm to fold false, got %v", condition) { return }
		if !testing.expect(t, collect_when_arm(&collection, &file, index, condition) == nil) { return }
	}
	testing.expect(t, scope_lookup_current(&scopes, package_scope, "IS_MAGIC") == 0)
}

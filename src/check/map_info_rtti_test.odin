package check

import "core:testing"
import "oc:syntax"
import "oc:types"

// Maps that only surface through runtime type info (printed or reflected but
// never indexed) still get cell and map info published for them.
@(test)
map_info_publish_covers_rtti_only_maps :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
Table :: map[string]int
`)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expectf(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0, "%v", parser.errors) { return }

	store := types.init()
	defer types.destroy(&store)
	builtin_types := seed_builtin_types(&store)
	integer, word, boolean := builtin_types.int, builtin_types.uintptr, builtin_types.boolean
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return }
	defer scope_store_destroy(&scopes)
	universe, scope_error := scope_create(&scopes, 0, .Universal)
	if !testing.expect(t, scope_error == nil) { return }
	package_scope, package_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, package_error == nil && file_error == nil) { return }
	if !testing.expect(t, bind_builtin_types(&scopes, universe, builtin_types) == nil) { return }
	if !testing.expect(t, bind_universe_builtins(&scopes, universe) == nil && bind_universe_constants(&scopes, universe, &pool)) { return }
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
	if !testing.expect(t, collect_file(&collection, &file, 1, {}) == nil && len(collection.diagnostics) == 0) { return }
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
	) { return }
	defer expression_checker_destroy(&checker)
	table: types.Type_Id
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		if !testing.expectf(t, err == nil && state != .Invalid, "%v %v", state, err) { return }
		if entity_get(&scopes, declaration.entity).name == "Table" { table = entity_get(&scopes, declaration.entity).type }
	}
	if !testing.expect(t, table != types.TYPE_NONE) { return }
	for plan in checker.plans {
		_, is_info := plan.(Map_Info_Plan)
		if !testing.expect(t, !is_info, "rtti-only map must not plan map info during checking") { return }
	}

	program: Checked_Program
	program.runtime.type_info = make([]Type_Info_Entry, 1, context.allocator)
	defer delete(program.runtime.type_info)
	program.runtime.type_info[0].type = table
	if !testing.expect(t, expression_checker_publish_map_cell_info(&checker, &program) == nil) { return }
	testing.expect_value(t, len(program.runtime.map_cell_info), 2)
	if !testing.expect(t, expression_checker_publish_map_info(&checker, &program) == nil) { return }
	if !testing.expect_value(t, len(program.runtime.map_info), 1) { return }
	testing.expect(t, program.runtime.map_info[0].type == types.resolve_named(checker.type_checker.store, table))
}

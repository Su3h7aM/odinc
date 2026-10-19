package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
map_info_builtins_check_map_types_and_publish_cell_info :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Name :: distinct string
Table :: map[string]int
Allocator :: struct { data: rawptr }
array: [dynamic]int
table: Table
array_allocator := array.allocator
map_allocator := table.allocator
Map_Info :: struct { ks, vs: rawptr }
Map_Cell_Info :: struct { size_of_type, align_of_type, size_of_cell, elements_per_cell: uintptr }
default_hasher_fixed :: proc "contextless" (data: rawptr, seed: uintptr, size: int) -> uintptr { return seed }
default_hasher_string :: proc "contextless" (data: rawptr, seed: uintptr) -> uintptr { return seed }
default_hasher_string16 :: proc "contextless" (data: rawptr, seed: uintptr) -> uintptr { return seed }
default_hasher_f64 :: proc "contextless" (value: f64, seed: uintptr) -> uintptr { return seed }
memory_equal :: proc "contextless" (x, y: rawptr, n: int) -> bool { return true }
cell := type_map_cell_info(Name)
info := type_map_info(Table)
bad_info := type_map_info(Name)
`,
	)
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
	for binding in ([?]struct {
			name: string,
			kind: Builtin_Kind,
		}{{"type_map_cell_info", .Type_Map_Cell_Info}, {"type_map_info", .Type_Map_Info}}) {
		builtin, builtin_error := expression_builtin_id(&checker, binding.kind)
		id, create_error := entity_create(&scopes, Entity{name = binding.name, kind = .Builtin, scope = universe, state = .Resolved, data = builtin})
		_, insert_error := scope_insert(&scopes, universe, id)
		if !testing.expect(t, builtin_error == nil && create_error == nil && insert_error == nil) { return }
	}
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		name := entity_get(&scopes, declaration.entity).name
		testing.expectf(t, err == nil && (state == .Invalid) == (name == "bad_info"), "%s: %v %v", name, state, err)
	}
	program: Checked_Program
	if !testing.expect(t, expression_checker_publish_map_cell_info(&checker, &program) == nil) { return }
	entries := program.runtime.map_cell_info
	if !testing.expect_value(t, len(entries), 2) { return }
	testing.expect_value(t, entries[0].size_of_type, 16)
	testing.expect_value(t, entries[0].size_of_cell, 64)
	testing.expect_value(t, entries[0].elements_per_cell, 4)
	if !testing.expect(t, expression_checker_publish_map_info(&checker, &program) == nil) { return }
	testing.expect_value(t, len(program.runtime.helper_entities), 5)
	testing.expect_value(t, len(checker.procedures), 2)
}

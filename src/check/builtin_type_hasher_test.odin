package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
type_hasher_proc_plans_and_publishes_generated_hasher :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Pt :: struct { a, b: int }
default_hasher_fixed :: proc "contextless" (data: rawptr, seed: uintptr, size: int) -> uintptr { return seed }
default_hasher_string :: proc "contextless" (data: rawptr, seed: uintptr) -> uintptr { return seed }
default_hasher_f64 :: proc "contextless" (value: f64, seed: uintptr) -> uintptr { return seed }
memory_equal :: proc "contextless" (x, y: rawptr, n: int) -> bool { return true }
map_seed :: proc "contextless" (map_value: Raw_Map) -> uintptr { return map_value.data }
map_cap :: proc "contextless" (map_value: Raw_Map) -> int { return int(map_value.data) }
map_kvh_data_dynamic :: proc "contextless" (map_value: Raw_Map, info: ^Map_Info) -> (ks, vs: uintptr, hs: [^]Map_Hash, sk, sv: uintptr) { return }
map_cell_index_dynamic :: proc "contextless" (base: uintptr, info: ^Map_Cell_Info, index: uintptr) -> uintptr { return base }
map_hash_is_valid :: proc "contextless" (hash: Map_Hash) -> bool { return hash != 0 }
__dynamic_map_get :: proc "contextless" (map_value: ^Raw_Map, info: ^Map_Info, hash: Map_Hash, key: rawptr) -> rawptr { return nil }
__dynamic_map_set :: proc (map_value: ^Raw_Map, info: ^Map_Info, hash: Map_Hash, key, value: rawptr, loc: Source_Code_Location) -> (value_ptr: rawptr, err: Allocator_Error) { return nil, .None }
__dynamic_map_reserve :: proc (map_value: ^Raw_Map, info: ^Map_Info, new_capacity: uint, loc: Source_Code_Location) -> Allocator_Error { return .None }
Map_Info :: struct { ks, vs: rawptr }
Map_Cell_Info :: struct { size_of_type, align_of_type, size_of_cell, elements_per_cell: uintptr }
Raw_Map :: struct { data, len: uintptr }
Map_Hash :: distinct uintptr
Allocator_Error :: enum byte { None }
Source_Code_Location :: struct { file_path: string, line, column: i32, procedure: string }
hasher := type_hasher_proc(Pt)
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
	checker_error := expression_checker_init(
		&checker,
		&type_checker,
		&pool,
		{uintptr = builtin_types.uintptr, layout = types.DEFAULT_LAYOUT},
		builtin_types.int,
		builtin_types.boolean,
		context.allocator,
	)
	if !testing.expect(t, checker_error == nil) { return }
	defer expression_checker_destroy(&checker)
	builtin, builtin_error := expression_builtin_id(&checker, .Type_Hasher_Proc)
	id, create_error := entity_create(&scopes, Entity{name = "type_hasher_proc", kind = .Builtin, scope = universe, state = .Resolved, data = builtin})
	_, insert_error := scope_insert(&scopes, universe, id)
	if !testing.expect(t, builtin_error == nil && create_error == nil && insert_error == nil) { return }
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		testing.expectf(t, err == nil && state != .Invalid, "%s: %v %v", entity_get(&scopes, declaration.entity).name, state, err)
	}
	planned := false
	for plan in checker.plans {
		requested, is_builtin := plan.(Builtin_Plan)
		planned ||= is_builtin && checker.builtin_kinds[requested.builtin] == .Type_Hasher_Proc
	}
	testing.expect(t, planned)
	if !testing.expect(t, expression_checker_publish_type_hashers(&checker) == nil) { return }
	hashers := 0
	for procedure in checker.procedures {
		if procedure.generated.kind == .Hasher { hashers += 1 }
	}
	testing.expect_value(t, hashers, 1)
}

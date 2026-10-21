package check

import "core:testing"
import "oc:syntax"
import "oc:types"

// Struct and union comparisons lower through generated equality procedures that call runtime
// helpers, so checking the comparison must resolve those helpers like map code does.
@(test)
comparison_resolves_generated_equality_helpers :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Pair :: struct { c: cstring, s: string }
default_hasher_fixed :: proc "contextless" (data: rawptr, seed: uintptr, size: int) -> uintptr { return seed }
default_hasher_string :: proc "contextless" (data: rawptr, seed: uintptr) -> uintptr { return seed }
default_hasher_string16 :: proc "contextless" (data: rawptr, seed: uintptr) -> uintptr { return seed }
default_hasher_cstring :: proc "contextless" (data: rawptr, seed: uintptr) -> uintptr { return seed }
default_hasher_cstring16 :: proc "contextless" (data: rawptr, seed: uintptr) -> uintptr { return seed }
default_hasher_f64 :: proc "contextless" (value: f64, seed: uintptr) -> uintptr { return seed }
memory_equal :: proc "contextless" (x, y: rawptr, n: int) -> bool { return true }
cstring_eq :: proc "contextless" (lhs, rhs: cstring) -> bool { return true }
cstring16_eq :: proc "contextless" (lhs, rhs: cstring16) -> bool { return true }
map_seed :: proc "contextless" () -> uintptr { return 0 }
map_cap :: proc "contextless" () -> int { return 0 }
map_kvh_data_dynamic :: proc "contextless" () { }
map_cell_index_dynamic :: proc "contextless" () -> uintptr { return 0 }
map_hash_is_valid :: proc "contextless" () -> bool { return true }
__dynamic_map_get :: proc "contextless" () -> rawptr { return nil }
__dynamic_map_set :: proc "contextless" () { }
__dynamic_map_reserve :: proc "contextless" () { }
compare :: proc "contextless" (a, b: Pair) -> bool { return a == b }
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
	compare_entity := scope_lookup_current(&scopes, package_scope, "compare")
	if !testing.expect(t, compare_entity != 0) { return }
	state, resolve_error := resolve_entity(&resolver, compare_entity)
	if !testing.expect(t, resolve_error == nil && state == .Resolved) { return }
	has_comparison_plan := false
	for plan in checker.plans {
		_, is_comparison := plan.(Comparison_Plan)
		has_comparison_plan ||= is_comparison
	}
	testing.expect(t, has_comparison_plan)
	for name in ([]string{"memory_equal", "cstring_eq"}) {
		helper := scope_lookup_current(&scopes, package_scope, name)
		if !testing.expect(t, helper != 0) { continue }
		testing.expectf(t, entity_get(&scopes, helper).state == .Resolved, "%s must be resolved for generated equality", name)
	}
}

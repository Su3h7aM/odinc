package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
contextual_composites_and_bit_sets :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Pair :: struct {left, right: int}
value: Pair = {1, 2}
array: [3]int = {2 = 9}
Flags :: enum {A, B, C}
mask :: bit_set[Flags]{.A, .C}
empty :: bit_set[Flags]{}
lanes := #simd[4]u8{1, 2, 3, 4}
partial_lanes := #simd[4]u8{7}
enumerated: [Flags]int = {.C = 9}
Levels :: enum {Low = 1, Mid, High}
shifted: [Levels]int = {.Mid = 9, .High = 2}
partial_levels: [Levels]int = {9}
duplicate := [2]int{0 = 1, 0 = 2}
bounds := [2]int{2 = 1}
pairs :: [2]Pair{{1, 2}, {3, 4}}
ranged := [?]int{5 ..= 6 = 54}
gapped :: [4]int{3 = 2}
defaults :: [2]Pair{{}, {}}
nested :: [1]struct {inner: Pair}{{}}
Styled :: struct {flags: bit_set[Flags], count: int}
styled :: Styled{count = 1}
Choice :: union {int, u8}
Carrier :: struct {choice: Choice, count: int}
carrier :: Carrier{count = 1}
painted :: Carrier{choice = 7, count = 2}
casted :: Carrier{choice = Choice(u8(3)), count = 4}
banners :: []int{1, 2}
greeting :: "Hello, " + "World!"
spread :: []int{0 = 7, 5 ..= 6 = 54, 10 ..< 12 = 8}
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
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	boolean := types.intern(&store, types.Type{kind = .Bool})
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
	builtins := []struct {
		name: string,
		type: types.Type_Id,
	}{{"int", integer}, {"u8", byte_type}, {"uintptr", word}, {"bool", boolean}}
	for builtin in builtins {
		id, create_error := entity_create(&scopes, Entity{name = builtin.name, kind = .Type_Name, scope = universe, state = .Resolved, type = builtin.type})
		_, insert_error := scope_insert(&scopes, universe, id)
		if !testing.expect(t, create_error == nil && insert_error == nil) { return }
	}
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
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
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		name := entity_get(&scopes, declaration.entity).name
		invalid := name == "duplicate" || name == "bounds" || name == "partial_levels"
		testing.expectf(t, err == nil && (state == .Invalid) == invalid, "%s: %v %v", name, state, err)
	}
	styled := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "styled"))
	testing.expect(t, styled.state == .Resolved)
	carrier := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "carrier"))
	testing.expect(t, carrier.state == .Resolved)
	painted := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "painted"))
	testing.expect(t, painted.state == .Resolved)
	casted := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "casted"))
	testing.expect(t, casted.state == .Resolved)
	greeting := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "greeting"))
	testing.expect(t, greeting.state == .Resolved)
	banners := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "banners"))
	testing.expect(t, banners.state == .Resolved)
	spread := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "spread"))
	testing.expect(t, spread.state == .Resolved)
	shifted := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "shifted"))
	shifted_array := types.get(&store, shifted.type)
	testing.expect(t, shifted_array.kind == .Enumerated_Array && shifted_array.lower_bound == 1 && shifted_array.count == 3)
}

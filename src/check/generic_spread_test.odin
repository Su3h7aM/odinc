package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
generic_spread_call_binds_the_slice_and_shares_the_packed_instance :: proc(t: ^testing.T) {
	// Official Odin accepts `f(&buf, ..xs)`, `g(1, ..xs)`, `g(1, ..ys)` (ys: []f32) and `g(1, 2, 3)`.
	source := transmute([]byte)string(
		`package sample
f :: proc(x: ^$T/[dynamic]$E, args: ..E) {}
g :: proc(first: $T, rest: ..T) -> T { return first }
xs: []int
ys: []f32
main :: proc() {
	buf: [dynamic]int
	f(&buf, ..xs)
	_ = g(1, ..xs)
	_ = g(1, 2, 3)
	_ = g(1, ..ys)
}
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
	boolean := types.intern(&store, types.Type{kind = .Bool})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return }
	defer scope_store_destroy(&scopes)
	universe, universe_error := scope_create(&scopes, 0, .Universal)
	package_scope, package_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, universe_error == nil && package_error == nil && file_error == nil) { return }
	if !testing.expect(t, bind_builtin_types(&scopes, universe, seed_builtin_types(&store)) == nil) { return }
	if !testing.expect(t, bind_universe_builtins(&scopes, universe) == nil) { return }
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
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		name := entity_get(&scopes, declaration.entity).name
		if !testing.expectf(t, err == nil && state == .Resolved, "%s: %v %v %v", name, state, err, checker.diagnostics) { return }
	}
	testing.expectf(t, len(checker.diagnostics) == 0, "%v", checker.diagnostics)
	g_entity := scope_lookup_current(&scopes, package_scope, "g")
	instances: [3]Entity_Id
	instance_count := 0
	for plan in checker.plans {
		call, is_call := plan.(Call_Plan)
		if !is_call || instance_count == len(instances) { continue }
		procedure, is_procedure := entity_get(&scopes, call.entity).data.(Procedure_Data)
		if !is_procedure || procedure.definition != g_entity { continue }
		instances[instance_count] = call.entity
		instance_count += 1
	}
	if !testing.expectf(t, instance_count == 3, "expected three calls to g, got %d", instance_count) { return }
	testing.expect(t, instances[0] == instances[1], "g(1, ..xs) and g(1, 2, 3) share one instance")
	testing.expect(t, instances[0] != instances[2], "g(1, ..ys) with f32 is a different instance")
}

@(test)
generic_spread_call_rejects_what_official_rejects :: proc(t: ^testing.T) {
	rejections := []struct {
		source: string,
		reason: string,
	} {
		{
			`package sample
f :: proc(x: ^$T/[dynamic]$E, args: ..E) {}
ys: []f32
main :: proc() {
	buf: [dynamic]int
	f(&buf, ..ys)
}
`,
			// Official Odin: "Cannot assign value 'ys' of type '[]f32' to '[]int' in a procedure argument".
			"Generic_Call_Spread_Type",
		},
		{
			`package sample
f :: proc(x: ^$T/[dynamic]$E, args: ..E) {}
xs: []int
main :: proc() {
	buf: [dynamic]int
	f(&buf, 1, ..xs)
}
`,
			// Official Odin: "'..' in a variadic procedure can only have one variadic argument at the end".
			"Call_Variadic_Spread_Arguments",
		},
		{
			`package sample
g :: proc(first: $T, rest: ..T) -> T { return first }
xs: []int
main :: proc() {
	_ = g(..xs)
}
`,
			// Official Odin: "'..' in the wrong position".
			"Call_Variadic_Spread_Position",
		},
	}
	for rejection in rejections {
		rejected, rejected_ok := check_procedure_source(t, transmute([]byte)rejection.source, .Unsupported, rejection.reason)
		if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
	}
}

@(test)
group_call_accepts_generic_member_with_spread_and_named_arguments :: proc(t: ^testing.T) {
	// Official Odin accepts `g(1, ..xs)`, `g(1, ..ys)` and `k(1, second = "x")` through the group.
	source := transmute([]byte)string(
		`package sample
g :: proc{g_poly, g_one}
g_poly :: proc(first: $T, rest: ..T) -> T { return first }
g_one :: proc(x: string) -> int { return 0 }
k :: proc{k_poly, k_one}
k_poly :: proc(first: $T, second: $U) -> T { return first }
k_one :: proc(x: string) -> int { return 0 }
xs: []int
ys: []f32
main :: proc() {
	_ = g(1, ..xs)
	_ = g(1, ..ys)
	_ = k(1, second = "x")
}
`,
	)
	procedure, ok := check_procedure_source(t, source, .None, "", 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

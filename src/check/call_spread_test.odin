package check

import "core:math/big"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
spread_call_binds_the_slice_to_the_variadic_parameter :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
sum :: proc (first: int, nums: ..int, scale := 1) -> int { return first }
f :: proc (nums: ..int, scale := 1) {}
xs: []int
main :: proc() {
	scaled := sum(1, ..xs, scale = 2)
	plain := sum(1, ..xs)
	f(..xs)
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
	testing.expect(t, len(checker.diagnostics) == 0)
	sum_entity := scope_lookup_current(&scopes, package_scope, "sum")
	parameters := entity_get(&scopes, sum_entity).data.(Procedure_Data).parameters
	if !testing.expect(t, len(parameters) == 3) { return }
	calls: [2]Call_Plan
	call_count := 0
	for plan in checker.plans {
		call, is_call := plan.(Call_Plan)
		if is_call && call.entity == sum_entity && call_count < len(calls) {
			calls[call_count] = call
			call_count += 1
		}
	}
	if !testing.expectf(t, call_count == 2, "expected two calls to sum, got %d", call_count) { return }
	scales: [2]i64
	scale_count := 0
	for call in calls {
		if !testing.expect(t, len(call.arguments) == 3) { continue }
		testing.expect(t, call.arguments[0].parameter == parameters[0])
		testing.expect(t, call.arguments[1].parameter == parameters[1])
		testing.expect(t, call.arguments[1].variadic_spread)
		testing.expect(t, !call.arguments[1].variadic_pack)
		testing.expect(t, call.arguments[2].parameter == parameters[2])
		#partial switch value in call.arguments[2].value {
		case Const_Id:
			constant := constant_pool_get(checker.constants, value)
			if constant == nil { continue }
			number, is_int := constant.value.(big.Int)
			if !is_int { continue }
			scale, conversion_error := big.get_i64(&number)
			if conversion_error != nil { continue }
			if scale_count < len(scales) {
				scales[scale_count] = scale
				scale_count += 1
			}
		}
	}
	if !testing.expect(t, scale_count == 2) { return }
	testing.expect(t, (scales[0] == 2 && scales[1] == 1) || (scales[0] == 1 && scales[1] == 2), "the named scale is 2 and the default scale is 1")
}

@(test)
spread_call_rejects_extra_positional_and_non_variadic_callees :: proc(t: ^testing.T) {
	rejections := []struct {
		source: string,
		reason: string,
	} {
		{
			`package sample
sum :: proc (first: int, nums: ..int) -> int { return first }
xs: []int
main :: proc() {
	bad := sum(1, 2, ..xs)
}
`,
			// Official Odin: "Cannot convert untyped value '2' to '[]int'" and ".." in a variadic procedure can only have one variadic argument at the end.
			"Call_Variadic_Spread_Arguments",
		},
		{
			`package sample
f :: proc (nums: ..int, scale := 1) {}
xs: []int
main :: proc() {
	f(1, ..xs, scale = 2)
}
`,
			// Official Odin: "Cannot convert untyped value '1' to '[]int'" and ".." in a variadic procedure can only have one variadic argument at the end.
			"Call_Variadic_Spread_Arguments",
		},
		// Official Odin: "Cannot use '..' in call to a non-variadic procedure: 'plain'".
		{`package sample
plain :: proc (a: int, b: int) -> int { return a }
xs: []int
main :: proc() {
	bad := plain(1, ..xs)
}
`, "Call_Variadic_Spread"},
		{
			`package sample
sum :: proc (first: int, second: int, nums: ..int) -> int { return first }
xs: []int
main :: proc() {
	bad := sum(1, ..xs)
}
`,
			"Call_Variadic_Spread_Position",
		},
		{
			`package sample
sum :: proc (first: int, nums: ..int) -> int { return first }
xs: []int
main :: proc() {
	bad := sum(..xs)
}
`,
			// Official Odin: ".." in the wrong position.
			"Call_Variadic_Spread_Position",
		},
	}
	for rejection in rejections {
		rejected, rejected_ok := check_procedure_source(t, transmute([]byte)rejection.source, .Unsupported, rejection.reason)
		if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
	}
}

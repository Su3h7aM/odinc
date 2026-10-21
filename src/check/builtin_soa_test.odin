package check

import "core:testing"
import "oc:syntax"
import "oc:types"

// Every universal builtin name must resolve to its kind. The ids are positionally coupled to the
// seeding order in expression_checker_init, so this table fails loudly on any misalignment.
@(test)
universe_builtin_pairing :: proc(t: ^testing.T) {
	expected := [?]struct {
		name: string,
		kind: Builtin_Kind,
	} {
		{"len", .Len},
		{"cap", .Cap},
		{"size_of", .Size_Of},
		{"align_of", .Align_Of},
		{"min", .Min},
		{"max", .Max},
		{"abs", .Abs},
		{"clamp", .Clamp},
		{"typeid_of", .Typeid_Of},
		{"type_info_of", .Type_Info_Of},
		{"unreachable", .Unreachable},
		{"raw_data", .Raw_Data},
		{"offset_of", .Offset_Of},
		{"offset_of_by_string", .Offset_Of_By_String},
		{"complex", .Complex},
		{"quaternion", .Quaternion},
		{"real", .Real},
		{"imag", .Imag},
		{"jmag", .Jmag},
		{"kmag", .Kmag},
		{"conj", .Conj},
		{"swizzle", .Swizzle},
		{"soa_zip", .Soa_Zip},
		{"soa_unzip", .Soa_Unzip},
	}
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
	universe, universe_error := scope_create(&scopes, 0, .Universal)
	if !testing.expect(t, universe_error == nil) { return }
	if !testing.expect(t, bind_universe_builtins(&scopes, universe) == nil) { return }
	checker: Expression_Checker
	resolver: Resolver
	resolver_init(&resolver, &scopes, expression_declaration, &checker, context.allocator)
	defer resolver_destroy(&resolver)
	type_checker: Type_Checker
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	type_checker_init(&type_checker, &resolver, &collection, &store, nil, expression_integer_evaluator, &checker, context.allocator)
	defer type_checker_destroy(&type_checker)
	if !testing.expect(
		t,
		expression_checker_init(&checker, &type_checker, &pool, {uintptr = word, layout = types.DEFAULT_LAYOUT}, integer, boolean, context.allocator) == nil,
	) { return }
	defer expression_checker_destroy(&checker)
	for entry in expected {
		id := scope_lookup_current(&scopes, universe, entry.name)
		if !testing.expectf(t, id != 0, "%s is not bound in the universe scope", entry.name) { continue }
		entity := entity_get(&scopes, id)
		if !testing.expectf(t, entity.kind == .Builtin, "%s is not a builtin", entry.name) { continue }
		builtin, is_id := entity.data.(Builtin_Id)
		if !testing.expectf(t, is_id, "%s has no builtin id", entry.name) { continue }
		testing.expectf(
			t,
			int(builtin) < len(checker.builtin_kinds) && checker.builtin_kinds[builtin] == entry.kind,
			"%s binds id %d kind %v",
			entry.name,
			builtin,
			checker.builtin_kinds[builtin] if int(builtin) < len(checker.builtin_kinds) else Builtin_Kind.None,
		)
	}
}

// soa_zip accepts named and positional slices, honors a matching #soa hint, and soa_unzip recovers the
// field slices. Resolution is the whole assertion: lowering soa values is phase 2, so the results are
// only named, never executed.
@(test)
soa_zip_unzip_resolve :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Vec :: struct { a: i32, b: f32 }
x := []i32{1, 3, 9}
y := []f32{2, 4, 16}
named := soa_zip(a = x, b = y)
positional := soa_zip(x, y)
hinted: #soa[]Vec = soa_zip(a = x, b = y)
g_a: []i32
g_b: []f32
use :: proc() {
	_, _ = positional, hinted
	back_a, back_b := soa_unzip(named)
	g_a, g_b = back_a, back_b
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
	builtin_types := seed_builtin_types(&store)
	integer, word, boolean := builtin_types.int, builtin_types.uintptr, builtin_types.boolean
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
		if !testing.expectf(t, err == nil && state == .Resolved, "%s: %v %v", name, state, err) { return }
	}
	if !testing.expect_value(t, len(checker.diagnostics), 0) { return }
	named_type := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "named")).type
	named_descriptor := types.get(&store, named_type)
	if !testing.expect(t, named_descriptor.kind == .Struct && named_descriptor.soa == .Slice) { return }
	elem_descriptor := types.get(&store, types.resolve_named(&store, named_descriptor.soa_elem))
	if !testing.expect(t, elem_descriptor.kind == .Struct && len(elem_descriptor.fields) == 2) { return }
	x_type := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "x")).type
	y_type := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "y")).type
	x_elem := types.get(&store, x_type).elem
	y_elem := types.get(&store, y_type).elem
	testing.expect(t, elem_descriptor.fields[0].name == "a" && types.are_identical(&store, elem_descriptor.fields[0].type, x_elem))
	testing.expect(t, elem_descriptor.fields[1].name == "b" && types.are_identical(&store, elem_descriptor.fields[1].type, y_elem))
	hinted_type := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "hinted")).type
	hinted_descriptor := types.get(&store, hinted_type)
	vec_type := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "Vec")).type
	testing.expect(
		t,
		hinted_descriptor.soa == .Slice &&
		types.are_identical(&store, types.resolve_named(&store, hinted_descriptor.soa_elem), types.resolve_named(&store, vec_type)),
	)
	// The g_a, g_b assignment above already proves the two results are []i32 and []f32:
	// any other arity or type would have failed conversion with a diagnostic.
}

// Each misuse rule upstream enforces must reject here with the matching verdict.
@(test)
soa_builtin_misuse :: proc(t: ^testing.T) {
	cases := [?]struct {
		name:   string,
		source: string,
		reason: string,
	} {
		{"zip_arity", `package sample
f :: proc(x: []i32) { s := soa_zip(); _ = s }`, "too few arguments for 'soa_zip', expected 1, got 0"},
		{"zip_slice", `package sample
f :: proc(x: int) { s := soa_zip(a = x); _ = s }`, "indices to 'soa_zip' must be slices"},
		{
			"zip_mixture",
			`package sample
f :: proc(x, y: []i32) { s := soa_zip(x, b = y); _ = s }`,
			"mixture of 'field = value' and value elements in 'soa_zip' is not allowed",
		},
		{"zip_duplicate", `package sample
f :: proc(x, y: []i32) { s := soa_zip(a = x, a = y); _ = s }`, "field argument name 'a' already exists"},
		{"zip_blank", `package sample
f :: proc(x: []i32) { s := soa_zip(_ = x); _ = s }`, "field argument name '_' is not allowed"},
		{"unzip_arity_few", `package sample
f :: proc() { a := soa_unzip(); _ = a }`, "too few arguments for 'soa_unzip', expected 1, got 0"},
		{"unzip_arity_many", `package sample
f :: proc(x, y: []i32) { a := soa_unzip(x, y); _ = a }`, "too many arguments for 'soa_unzip', expected 1, got 2"},
		{"unzip_slice", `package sample
f :: proc(x: []i32) { a, b := soa_unzip(x); _, _ = a, b }`, "'soa_unzip' expects an #soa slice"},
	}
	for entry in cases {
		_, ok := check_procedure_source(
			t,
			transmute([]byte)entry.source,
			expected_kind = .Invalid_Operand,
			expected_reason = entry.reason,
			procedure_name = "f",
		)
		if !ok { testing.expectf(t, false, "%s failed", entry.name) }
	}
}

// A soa pattern matches only soa arguments, and a plain pattern only plain ones, in both directions.
@(test)
soa_pattern_matching :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Vec :: struct { x: i32 }
plain_only :: proc(array: ^$T/[dynamic]$E, arg: E) -> int { return 0 }
soa_only :: proc(array: ^$T/#soa[dynamic]$E, arg: E) -> int { return 1 }
pick :: proc{plain_only, soa_only}
soa_array: #soa[dynamic]Vec
plain_array: [dynamic]Vec
call_soa :: proc() -> int { return pick(&soa_array, Vec{1}) }
call_plain :: proc() -> int { return pick(&plain_array, Vec{1}) }
`,
	)
	call_soa, ok_soa := check_procedure_source(t, source, procedure_name = "call_soa")
	if !ok_soa || !testing.expect(t, call_soa.body_state == .Complete) { return }
	call_plain, ok_plain := check_procedure_source(t, source, procedure_name = "call_plain")
	if !ok_plain || !testing.expect(t, call_plain.body_state == .Complete) { return }
	reject_source := transmute([]byte)string(
		`package sample
Vec :: struct { x: i32 }
plain_only :: proc(array: ^$T/[dynamic]$E, arg: E) -> int { return 0 }
soa_only :: proc(array: ^$T/#soa[dynamic]$E, arg: E) -> int { return 1 }
soa_group :: proc{soa_only}
plain_group :: proc{plain_only}
plain_array: [dynamic]Vec
soa_array: #soa[dynamic]Vec
reject_soa :: proc() -> int { return soa_group(&plain_array, Vec{1}) }
reject_plain :: proc() -> int { return plain_group(&soa_array, Vec{1}) }
`,
	)
	check_procedure_source(t, reject_source, expected_kind = .No_Matching_Overload, diagnostic_count = 2, procedure_name = "reject_soa")
}

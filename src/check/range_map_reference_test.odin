package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
map_reference_values_are_addressable :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
map_seed :: proc "contextless" () {}
map_cap :: proc "contextless" () {}
map_kvh_data_dynamic :: proc "contextless" () {}
map_cell_index_dynamic :: proc "contextless" () {}
map_hash_is_valid :: proc "contextless" () {}
__dynamic_map_get :: proc "contextless" () {}
__dynamic_map_set :: proc "contextless" () {}
__dynamic_map_reserve :: proc "contextless" () {}
Record :: struct { value: int }
take_record :: proc "contextless" (record: ^Record) { record.value = 1 }
take_pointer :: proc "contextless" (record: ^^Record) { record^ = nil }
main :: proc "contextless" () {
	records: map[int]Record
	for _, &record in records { take_record(&record) }
	for _, &record in records { record.value = 2; _ = &record.value }
	pointers: map[int]^Record
	for _, &record in pointers { take_pointer(&record) }
	for _, record in pointers { record.value = 3 }
}
immutable_key :: proc "contextless" () {
	records: map[int]Record
	for key, &record in records { key = 1 }
}
immutable_value :: proc "contextless" () {
	records: map[int]Record
	for _, record in records { record.value = 1 }
}
unaddressable_key :: proc "contextless" () {
	records: map[int]Record
	for key, &record in records { _ = &key }
}
unaddressable_value :: proc "contextless" () {
	records: map[int]Record
	for _, record in records { take_record(&record) }
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
	builtins := seed_builtin_types(&store)
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
	if !testing.expect(t, bind_builtin_types(&scopes, universe, builtins) == nil) { return }
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
		expression_checker_init(
			&checker,
			&type_checker,
			&pool,
			{uintptr = builtins.uintptr, layout = types.DEFAULT_LAYOUT},
			builtins.int,
			builtins.boolean,
			context.allocator,
		) ==
		nil,
	) { return }
	defer expression_checker_destroy(&checker)
	main := scope_lookup_current(&scopes, package_scope, "main")
	state, err := resolve_entity(&resolver, main)
	testing.expectf(t, state == .Resolved && err == nil, "%v %v", state, err)
	testing.expectf(t, len(checker.diagnostics) == 0, "%v", checker.diagnostics)
	testing.expect(t, entity_get(&scopes, main).data.(Procedure_Data).body_state == .Complete)
	for entry in ([?]struct {
			name, reason: string,
		}{{"immutable_key", "Assign_Destination_Mode"}, {"immutable_value", "Assign_Destination_Mode"}, {"unaddressable_key", "Address_Mode"}, {"unaddressable_value", "Address_Mode"}}) {
		entity := scope_lookup_current(&scopes, package_scope, entry.name)
		before := len(checker.diagnostics)
		_, failure := resolve_entity(&resolver, entity)
		if !testing.expect_value(t, failure, nil) { continue }
		if !testing.expectf(t, len(checker.diagnostics) == before + 1, "%s: %v", entry.name, checker.diagnostics[before:]) { continue }
		diagnostic := checker.diagnostics[before]
		testing.expectf(t, diagnostic.kind == .Unsupported && diagnostic.reason == entry.reason, "%s: %v", entry.name, diagnostic)
		testing.expect(t, entity_get(&scopes, entity).data.(Procedure_Data).body_state == .Invalid)
	}
}

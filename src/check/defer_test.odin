package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(private = "package")
check_procedure_source :: proc(t: ^testing.T, source: []byte) -> (procedure: Procedure_Data, ok: bool) {
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expectf(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0, "%v", parser.errors) { return {}, false }
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return {}, false }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return {}, false }
	defer scope_store_destroy(&scopes)
	universe, universe_error := scope_create(&scopes, 0, .Universal)
	package_scope, package_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, universe_error == nil && package_error == nil && file_error == nil) { return {}, false }
	byte_id, byte_create_error := entity_create(&scopes, Entity{name = "u8", kind = .Type_Name, scope = universe, state = .Resolved, type = byte_type})
	_, byte_insert_error := scope_insert(&scopes, universe, byte_id)
	bool_id, bool_create_error := entity_create(&scopes, Entity{name = "bool", kind = .Type_Name, scope = universe, state = .Resolved, type = boolean})
	_, bool_insert_error := scope_insert(&scopes, universe, bool_id)
	if !testing.expect(t, byte_create_error == nil && byte_insert_error == nil && bool_create_error == nil && bool_insert_error == nil) { return {}, false }
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	if !testing.expect(t, collect_file(&collection, &file, 1, {}) == nil && len(collection.diagnostics) == 0) { return {}, false }
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
	) { return {}, false }
	defer expression_checker_destroy(&checker)
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		if !testing.expectf(t, err == nil && state == .Resolved, "%v %v", state, err) { return {}, false }
	}
	return entity_get(&scopes, collection.declarations[0].entity).data.(Procedure_Data), true
}

@(test)
defer_registers_checked_body_and_rejects_return :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	value: u8
	defer value = 7
}
`)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
	testing.expect_value(t, len(procedure.defers), 1)

	invalid := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	defer { return }
}
`)
	rejected, rejected_ok := check_procedure_source(t, invalid)
	if !rejected_ok { return }
	testing.expect(t, rejected.body_state == .Invalid)
}

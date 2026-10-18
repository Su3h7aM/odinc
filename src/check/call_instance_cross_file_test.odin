package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(private = "file")
check_last_procedure_across_files :: proc(t: ^testing.T, library_source, main_source: []byte) -> (procedure: Procedure_Data, ok: bool) {
	library_ast, main_ast: syntax.Ast
	syntax.ast_init(&library_ast, context.allocator)
	defer syntax.ast_destroy(&library_ast)
	syntax.ast_init(&main_ast, context.allocator)
	defer syntax.ast_destroy(&main_ast)
	library_parser, main_parser: syntax.Parser
	syntax.parser_init(&library_parser, &library_ast, library_source, context.allocator)
	defer syntax.parser_destroy(&library_parser)
	syntax.parser_init(&main_parser, &main_ast, main_source, context.allocator)
	defer syntax.parser_destroy(&main_parser)
	syntax.parse_file(&library_parser)
	syntax.parse_file(&main_parser)
	if !testing.expectf(t, len(library_parser.errors) == 0 && len(main_parser.errors) == 0, "%v %v", library_parser.errors, main_parser.errors) {
		return {}, false
	}

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
	library_scope, library_error := scope_create(&scopes, package_scope, .File)
	main_scope, main_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, universe_error == nil && package_error == nil && library_error == nil && main_error == nil) { return {}, false }
	byte_id, byte_create_error := entity_create(&scopes, Entity{name = "u8", kind = .Type_Name, scope = universe, state = .Resolved, type = byte_type})
	_, byte_insert_error := scope_insert(&scopes, universe, byte_id)
	if !testing.expect(t, byte_create_error == nil && byte_insert_error == nil) { return {}, false }
	runtime_scope, runtime_scope_error := scope_create(&scopes, universe, .Package)
	if !testing.expect(t, runtime_scope_error == nil) { return {}, false }
	context_type := types.intern(&store, types.Type{kind = .Struct, name = "Context", fields = []types.Type_Field{{name = "allocator", type = integer}}})
	context_id, context_create_error := entity_create(
		&scopes,
		Entity{name = "Context", kind = .Type_Name, scope = runtime_scope, state = .Resolved, type = context_type},
	)
	_, context_insert_error := scope_insert(&scopes, runtime_scope, context_id)
	if !testing.expect(t, context_create_error == nil && context_insert_error == nil) { return {}, false }

	library_file := File {
		package_id = 1,
		ast        = &library_ast,
		source     = library_source,
		scope      = library_scope,
	}
	main_file := File {
		package_id = 1,
		ast        = &main_ast,
		source     = main_source,
		scope      = main_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	collection.runtime_scope = runtime_scope
	if !testing.expect(t, collect_file(&collection, &library_file, 1, {}) == nil && len(collection.diagnostics) == 0) { return {}, false }
	if !testing.expect(t, collect_file(&collection, &main_file, 2, {}) == nil && len(collection.diagnostics) == 0) { return {}, false }
	checker: Expression_Checker
	resolver: Resolver
	resolver_init(&resolver, &scopes, expression_declaration, &checker, context.allocator)
	defer resolver_destroy(&resolver)
	type_checker: Type_Checker
	type_checker_init(
		&type_checker,
		&resolver,
		&collection,
		&store,
		[]^File{nil, &library_file, &main_file},
		expression_integer_evaluator,
		&checker,
		context.allocator,
	)
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
	return entity_get(&scopes, collection.declarations[len(collection.declarations) - 1].entity).data.(Procedure_Data), true
}

// The generic is declared in one file and called from another with a `.Name` argument; the hint comes from the
// callee's parameter type, which lives in the other file's AST.
@(test)
generic_call_selector_argument_uses_callee_file_parameter_type :: proc(t: ^testing.T) {
	library_source := transmute([]byte)string(
		`package sample
Color :: enum { Red, Green }
weight :: proc "contextless" (color: Color, value: $T) -> int {
	return 1
}
`,
	)
	main_source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	total := weight(.Green, 7)
	_ = total
}
`)
	procedure, ok := check_last_procedure_across_files(t, library_source, main_source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

package check

import "core:testing"
import "oc:syntax"
import "oc:types"

// A `when` condition naming a constant of a later pending `when` waits for it; the failed attempt leaves no state.
@(test)
when_condition_waits_for_a_constant_bound_by_a_later_when :: proc(t: ^testing.T) {
	first_source := transmute([]byte)string(`package sample
X :: Y
when X {
}
`)
	second_source := transmute([]byte)string(`package sample
when true {
	Y :: true
}
`)
	first_ast, second_ast: syntax.Ast
	syntax.ast_init(&first_ast, context.allocator)
	defer syntax.ast_destroy(&first_ast)
	syntax.ast_init(&second_ast, context.allocator)
	defer syntax.ast_destroy(&second_ast)
	first_parser, second_parser: syntax.Parser
	syntax.parser_init(&first_parser, &first_ast, first_source, context.allocator)
	defer syntax.parser_destroy(&first_parser)
	syntax.parser_init(&second_parser, &second_ast, second_source, context.allocator)
	defer syntax.parser_destroy(&second_parser)
	syntax.parse_file(&first_parser)
	syntax.parse_file(&second_parser)
	if !testing.expect(t, len(first_parser.errors) == 0 && len(second_parser.errors) == 0) { return }

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
	universe, _ := scope_create(&scopes, 0, .Universal)
	if !testing.expect(t, bind_universe_constants(&scopes, universe, &pool)) { return }
	package_scope, _ := scope_create(&scopes, universe, .Package)
	first_scope, _ := scope_create(&scopes, package_scope, .File)
	second_scope, _ := scope_create(&scopes, package_scope, .File)

	first_file := File {
		package_id = 1,
		ast        = &first_ast,
		source     = first_source,
		scope      = first_scope,
	}
	second_file := File {
		package_id = 1,
		ast        = &second_ast,
		source     = second_source,
		scope      = second_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	collection.runtime_scope = package_scope
	if !testing.expect(t, collect_file(&collection, &first_file, 1, {file_order = 0}) == nil) { return }
	if !testing.expect(t, collect_file(&collection, &second_file, 2, {file_order = 1}) == nil) { return }

	checker: Expression_Checker
	resolver: Resolver
	resolver_init(&resolver, &scopes, expression_declaration, &checker, context.allocator)
	defer resolver_destroy(&resolver)
	type_checker: Type_Checker
	files := []^File{nil, &first_file, &second_file}
	type_checker_init(&type_checker, &resolver, &collection, &store, files, expression_integer_evaluator, &checker, context.allocator)
	defer type_checker_destroy(&type_checker)
	if !testing.expect(
		t,
		expression_checker_init(&checker, &type_checker, &pool, {uintptr = word, layout = types.DEFAULT_LAYOUT}, integer, boolean, context.allocator) == nil,
	) { return }
	defer expression_checker_destroy(&checker)

	first_when, second_when := -1, -1
	for pending, index in collection.pending {
		if pending.kind != .When { continue }
		if pending.declaration.file == File_Id(1) { first_when = index } else { second_when = index }
	}
	if !testing.expect(t, first_when >= 0 && second_when >= 0) { return }

	first_declaration := collection.pending[first_when].declaration
	first_statement := syntax.node_payload(&first_ast, first_declaration.node, syntax.When_Stmt)
	_, first_ok, first_error := type_checker.evaluate_boolean(&type_checker, first_scope, first_declaration.file, first_statement.cond, type_checker.user_data)
	testing.expect(t, first_error == nil && !first_ok)

	second_declaration := collection.pending[second_when].declaration
	second_statement := syntax.node_payload(&second_ast, second_declaration.node, syntax.When_Stmt)
	second_condition, second_ok, second_error := type_checker.evaluate_boolean(
		&type_checker,
		second_scope,
		second_declaration.file,
		second_statement.cond,
		type_checker.user_data,
	)
	if !testing.expect(t, second_error == nil && second_ok && second_condition) { return }
	if !testing.expect(t, collect_when_arm(&collection, &second_file, second_when, second_condition) == nil) { return }

	first_condition, first_retry_ok, first_retry_error := type_checker.evaluate_boolean(
		&type_checker,
		first_scope,
		first_declaration.file,
		first_statement.cond,
		type_checker.user_data,
	)
	testing.expectf(
		t,
		first_retry_error == nil && first_retry_ok && first_condition,
		"error %v ok %v value %v",
		first_retry_error,
		first_retry_ok,
		first_condition,
	)
}

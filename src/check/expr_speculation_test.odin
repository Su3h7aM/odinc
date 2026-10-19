package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
speculation_end_truncates_plans_of_rejected_candidate :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
candidate := [2]any{1, 2}
`)
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
			{uintptr = builtin_types.uintptr, layout = types.DEFAULT_LAYOUT},
			builtin_types.int,
			builtin_types.boolean,
			context.allocator,
		) ==
		nil,
	) { return }
	defer expression_checker_destroy(&checker)
	view, view_error := expression_file_view(&checker, 1)
	if !testing.expect(t, view_error == nil && len(collection.declarations) == 1) { return }
	candidate := collection.declarations[0].value.node
	plans_before := len(checker.plans)
	mark := expression_speculation_begin(&checker)
	_, check_error := check_expression(&checker, view, file_scope, candidate, 0)
	testing.expect(t, check_error == nil && len(checker.plans) > plans_before)
	expression_speculation_end(&checker, mark)
	testing.expect(t, check_error == nil && len(checker.plans) == plans_before)
}

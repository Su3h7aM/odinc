package check

import "core:testing"
import "oc:syntax"
import "oc:types"

Speculation_Fixture :: struct {
	checker:       ^Expression_Checker,
	resolver:      ^Resolver,
	scopes:        ^Scope_Store,
	ast:           ^syntax.Ast,
	package_scope: Scope_Id,
}

@(test)
pending_body_drained_under_speculation_keeps_operands :: proc(t: ^testing.T) {
	speculation_fixture_run(
		t,
		`package sample
ordinary :: proc(p: ^int) -> bool { return p == nil }
identity :: proc(x: $T) -> T { return x }
candidate := identity(ordinary)
`,
		check_drained_operands_after_speculation,
	)
}

@(test)
generic_instance_body_queued_under_speculation_is_checked_once :: proc(t: ^testing.T) {
	speculation_fixture_run(t, `package sample
identity :: proc(x: $T) -> T { return missing }
candidate := identity(1)
`, check_generic_instance_checked_once)
}

@(private = "file")
check_drained_operands_after_speculation :: proc(t: ^testing.T, fixture: Speculation_Fixture) {
	candidate := scope_lookup_current(fixture.scopes, fixture.package_scope, "candidate")
	ordinary := scope_lookup_current(fixture.scopes, fixture.package_scope, "ordinary")
	view, view_error := expression_file_view(fixture.checker, 1)
	if !testing.expect(t, view_error == nil) { return }
	mark := expression_speculation_begin(fixture.checker)
	state, resolve_error := resolve_entity(fixture.resolver, candidate)
	expression_speculation_end(fixture.checker, mark)
	if !testing.expect(t, resolve_error == nil && state == .Resolved) { return }
	if !testing.expect(t, resolver_check_pending_bodies(fixture.resolver) == nil) { return }
	testing.expect(t, entity_get(fixture.scopes, ordinary).data.(Procedure_Data).body_state == .Complete)
	program: Checked_Program
	expression_checker_publish(fixture.checker, &program)
	for node, index in fixture.ast.nodes {
		if node.kind != .Binary_Expr { continue }
		binary := syntax.node_payload(fixture.ast, syntax.Node_Index(index), syntax.Binary_Expr)
		info, found := expression_info(&program, view, binary.left)
		testing.expectf(t, found && info.state == .Checked && info.type != types.TYPE_NONE, "left operand: %v", info)
	}
}

@(private = "file")
check_generic_instance_checked_once :: proc(t: ^testing.T, fixture: Speculation_Fixture) {
	candidate := scope_lookup_current(fixture.scopes, fixture.package_scope, "candidate")
	outer := expression_speculation_begin(fixture.checker)
	inner := expression_speculation_begin(fixture.checker)
	_, _ = resolve_entity(fixture.resolver, candidate)
	expression_speculation_end(fixture.checker, inner)
	expression_speculation_end(fixture.checker, outer)
	testing.expect_value(t, len(fixture.resolver.pending_bodies), 1)
	testing.expect_value(t, len(fixture.checker.diagnostics), 0)
	testing.expect(t, resolver_check_pending_bodies(fixture.resolver) == nil)
	testing.expect_value(t, len(fixture.resolver.pending_bodies), 0)
	testing.expect_value(t, len(fixture.checker.diagnostics), 1)
	if len(fixture.checker.diagnostics) == 1 {
		testing.expect(t, fixture.checker.diagnostics[0].kind == .Undeclared_Name)
	}
	testing.expect(t, resolver_check_pending_bodies(fixture.resolver) == nil)
	testing.expect_value(t, len(fixture.checker.diagnostics), 1)
}

@(private = "file")
speculation_fixture_run :: proc(t: ^testing.T, source: string, scenario: proc(t: ^testing.T, fixture: Speculation_Fixture)) {
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, transmute([]byte)source, context.allocator)
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
		source     = transmute([]byte)source,
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
	scenario(t, Speculation_Fixture{&checker, &resolver, &scopes, &ast, package_scope})
}

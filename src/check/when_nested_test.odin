package check

import "core:testing"
import "oc:syntax"
import "oc:types"

// A false nested `when` with `#panic` inside a true `when`, as core:thread's no-CRT file, must not stop the arm
// and its declaration must be visible to another file of the package.
@(test)
nested_false_when_with_panic_leaves_later_declarations_visible :: proc(t: ^testing.T) {
	early_source := transmute([]byte)string(`package thread
IS_SUPPORTED :: _IS_SUPPORTED
`)
	late_source := transmute([]byte)string(
		`#+build linux
#+private
package thread
when ODIN_NO_CRT {
	when ODIN_ARCH != .amd64 && ODIN_ARCH != .arm64 && ODIN_ARCH != .riscv64 {
		#panic("core:thread without CRT on Linux requires amd64, arm64, or riscv64")
	}
	_IS_SUPPORTED :: true
}
`,
	)
	early_ast, late_ast: syntax.Ast
	syntax.ast_init(&early_ast, context.allocator)
	defer syntax.ast_destroy(&early_ast)
	syntax.ast_init(&late_ast, context.allocator)
	defer syntax.ast_destroy(&late_ast)
	early_parser, late_parser: syntax.Parser
	syntax.parser_init(&early_parser, &early_ast, early_source, context.allocator)
	defer syntax.parser_destroy(&early_parser)
	syntax.parser_init(&late_parser, &late_ast, late_source, context.allocator)
	defer syntax.parser_destroy(&late_parser)
	syntax.parse_file(&early_parser)
	syntax.parse_file(&late_parser)
	if !testing.expect(t, len(early_parser.errors) == 0 && len(late_parser.errors) == 0) { return }

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
	early_scope, _ := scope_create(&scopes, package_scope, .File)
	late_scope, _ := scope_create(&scopes, package_scope, .File)

	early_file := File {
		package_id = 1,
		ast        = &early_ast,
		source     = early_source,
		scope      = early_scope,
	}
	late_file := File {
		package_id = 1,
		ast        = &late_ast,
		source     = late_source,
		scope      = late_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	collection.runtime_scope = package_scope
	if !testing.expect(t, collect_file(&collection, &early_file, 1, {file_order = 0}) == nil) { return }
	if !testing.expect(t, collect_file(&collection, &late_file, 2, {file_order = 1}) == nil) { return }

	checker: Expression_Checker
	resolver: Resolver
	resolver_init(&resolver, &scopes, expression_declaration, &checker, context.allocator)
	defer resolver_destroy(&resolver)
	type_checker: Type_Checker
	files := []^File{nil, &early_file, &late_file}
	type_checker_init(&type_checker, &resolver, &collection, &store, files, expression_integer_evaluator, &checker, context.allocator)
	defer type_checker_destroy(&type_checker)
	if !testing.expect(t, bind_universe_build_context(&type_checker, universe, &pool, DEFAULT_BUILD_CONFIGURATION)) { return }
	if !testing.expect(
		t,
		expression_checker_init(&checker, &type_checker, &pool, {uintptr = word, layout = types.DEFAULT_LAYOUT}, integer, boolean, context.allocator) == nil,
	) { return }
	defer expression_checker_destroy(&checker)

	for index := 0; index < len(collection.pending); index += 1 {
		pending := collection.pending[index]
		if pending.handled || pending.kind != .When { continue }
		file := files[pending.declaration.file]
		statement := syntax.node_payload(file.ast, pending.declaration.node, syntax.When_Stmt)
		condition, evaluated, evaluate_error := type_checker.evaluate_boolean(
			&type_checker,
			file.scope,
			pending.declaration.file,
			statement.cond,
			type_checker.user_data,
		)
		if !testing.expect(t, evaluate_error == nil && evaluated) { return }
		if !testing.expect(t, collect_when_arm(&collection, file, index, condition) == nil) { return }
	}
	if !testing.expect(t, len(collection.diagnostics) == 0) { return }
	testing.expect(t, scope_lookup_current(&scopes, package_scope, "_IS_SUPPORTED") != 0)

	for declaration in collection.declarations {
		state, resolve_error := resolve_entity(&resolver, declaration.entity)
		if !testing.expectf(
			t,
			resolve_error == nil && state == .Resolved,
			"%s %v %v",
			entity_get(&scopes, declaration.entity).name,
			state,
			resolve_error,
		) { return }
	}
}

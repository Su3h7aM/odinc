package check

import "core:math/big"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
import_aliases_and_blank_declarations_preserve_package_namespaces :: proc(t: ^testing.T) {
	library_source := transmute([]byte)string(`package library
Record :: struct { value: int }
Value :: 7
`)
	source := transmute([]byte)string(
		`package sample
import library "library"
renamed :: library
second :: renamed
_ :: library
_ :: second
original: library.Record
alias_value: renamed.Record = original
result :: second.Value
`,
	)
	library_ast, ast: syntax.Ast
	syntax.ast_init(&library_ast, context.allocator)
	defer syntax.ast_destroy(&library_ast)
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	library_parser, parser: syntax.Parser
	syntax.parser_init(&library_parser, &library_ast, library_source, context.allocator)
	defer syntax.parser_destroy(&library_parser)
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&library_parser)
	syntax.parse_file(&parser)
	if !testing.expect(t, len(library_parser.errors) == 0 && len(parser.errors) == 0) { return }
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
	library_scope, library_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	library_file_scope, library_file_error := scope_create(&scopes, library_scope, .File)
	if !testing.expect(t, universe_error == nil && package_error == nil && library_error == nil && file_error == nil && library_file_error == nil) { return }
	if !testing.expect(t, bind_builtin_types(&scopes, universe, builtins) == nil) { return }
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	library_file := File {
		package_id = 2,
		ast        = &library_ast,
		source     = library_source,
		scope      = library_file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	if !testing.expect(t, collect_file(&collection, &library_file, 1, {}) == nil && collect_file(&collection, &file, 2, {}) == nil) { return }
	if !testing.expect(t, len(collection.pending) == 1 && collect_import_name(&collection, &file, 0, "library", 2) == nil) { return }
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
		[]^File{nil, &library_file, &file},
		expression_integer_evaluator,
		&checker,
		context.allocator,
	)
	defer type_checker_destroy(&type_checker)
	packages := []Package{{}, {scope = package_scope, kind = .User}, {scope = library_scope, kind = .User}}
	type_checker.packages = packages
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
	checker.packages = packages
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		if !testing.expectf(
			t,
			state == .Resolved && err == nil,
			"%s: %v %v %v",
			entity_get(&scopes, declaration.entity).name,
			state,
			err,
			checker.diagnostics,
		) { return }
	}
	for name in ([?]string{"renamed", "second"}) {
		entity := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, name))
		testing.expect(t, entity.kind == .Import_Name && entity.data.(Import_Data).package_id == 2)
	}
	original := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "original"))
	alias_value := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "alias_value"))
	testing.expect(t, original.type == alias_value.type && scope_lookup_current(&scopes, package_scope, "_") == 0)
	result := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "result"))
	integer := constant_pool_get(&pool, result.constant).value.(big.Int)
	value, conversion_error := big.int_get_i64(&integer)
	testing.expect(t, conversion_error == nil && value == 7)
	testing.expect(t, len(checker.diagnostics) == 0 && len(type_checker.diagnostics) == 0)
}

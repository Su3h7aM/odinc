package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
unaligned_store_checks_pointer_element_and_arguments :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Pair :: struct { left, right: u64 }
scalar: u64
pair: Pair
valid :: proc() { unaligned_store(&scalar, 7); unaligned_store(&pair, pair) }
bad_pointer :: proc() { unaligned_store(scalar, 7) }
bad_value :: proc() { unaligned_store(&scalar, pair) }
bad_count :: proc() { unaligned_store(&scalar) }
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
	universe, scope_error := scope_create(&scopes, 0, .Universal)
	if !testing.expect(t, scope_error == nil) { return }
	package_scope, package_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, package_error == nil && file_error == nil) { return }
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
		expression_checker_init(&checker, &type_checker, &pool, {uintptr = word, layout = types.DEFAULT_LAYOUT}, integer, boolean, context.allocator) == nil,
	) { return }
	defer expression_checker_destroy(&checker)
	builtin, builtin_error := expression_builtin_id(&checker, intrinsic_builtin_kind("unaligned_store"))
	id, create_error := entity_create(&scopes, Entity{name = "unaligned_store", kind = .Builtin, scope = universe, state = .Resolved, data = builtin})
	_, insert_error := scope_insert(&scopes, universe, id)
	if !testing.expect(t, builtin_error == nil && create_error == nil && insert_error == nil) { return }
	for declaration in collection.declarations {
		_, err := resolve_entity(&resolver, declaration.entity)
		testing.expect(t, err == nil)
	}
	testing.expect_value(t, len(checker.diagnostics), 3)
	invalid_operands, mismatched_types := 0, 0
	for diagnostic in checker.diagnostics {
		#partial switch diagnostic.kind {
		case .Invalid_Operand:
			invalid_operands += 1
		case .Mismatched_Types:
			mismatched_types += 1
		case:
			testing.expectf(t, false, "unexpected diagnostic kind %v", diagnostic.kind)
		}
	}
	testing.expect_value(t, invalid_operands, 2)
	testing.expect_value(t, mismatched_types, 1)
	stores := 0
	for plan in checker.plans {
		if builtin_plan, ok := plan.(Builtin_Plan); ok && checker.builtin_kinds[builtin_plan.builtin] == .Unaligned_Store {
			testing.expect_value(t, len(builtin_plan.arguments), 2)
			stores += 1
		}
	}
	testing.expect_value(t, stores, 2)
}

package check

import "core:math/big"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
builtin_batch_preserves_constants_and_call_plans :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Rank :: enum u8 { Middle = 7, Low = 2, High = 19, Last = 4 }
low :: min(Rank)
high :: max(Rank)
minimum :: min(9, 5, 7, 6)
maximum :: max(2, u8(8), 4)
absolute :: abs(-17)
clamped :: clamp(12, 2, 9)
fraction :: min(1.5, 2.5)
runtime_value: u8
runtime_maximum := max(1, runtime_value, 9, 7)
log_zero :: constant_log2(0)
log_negative :: constant_log2(-32)
log_wide :: constant_log2(1 << 100)
Type_Info :: struct { size, align: int, id: typeid }
type_table: []^Type_Info
__type_info_of :: proc "contextless" (id: typeid) -> ^Type_Info { return nil }
info := type_info_of(Rank)
info_dynamic := type_info_of(typeid_of(Rank))
bad_extremum :: max(u8(2))
bad_log := constant_log2(runtime_value)
bad_info := type_info_of(runtime_value)
bad_arity := clamp(1, 2)
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
	builtin, builtin_error := expression_builtin_id(&checker, .Constant_Log2)
	id, create_error := entity_create(&scopes, Entity{name = "constant_log2", kind = .Builtin, scope = universe, state = .Resolved, data = builtin})
	_, insert_error := scope_insert(&scopes, universe, id)
	if !testing.expect(t, builtin_error == nil && create_error == nil && insert_error == nil) { return }
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		name := entity_get(&scopes, declaration.entity).name
		invalid := name == "bad_extremum" || name == "bad_log" || name == "bad_info" || name == "bad_arity"
		testing.expectf(t, err == nil && (state == .Invalid) == invalid, "%s: %v %v", name, state, err)
	}
	for expected in ([?]struct {
			name:  string,
			value: i64,
		}{{"low", 2}, {"high", 19}, {"minimum", 5}, {"maximum", 8}, {"absolute", 17}, {"clamped", 9}, {"log_zero", -1}, {"log_negative", 5}, {"log_wide", 100}}) {
		entity := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, expected.name))
		constant := constant_pool_get(&pool, entity.constant)
		if !testing.expectf(t, constant != nil, "%s must fold", expected.name) { continue }
		value, integer := constant.value.(big.Int)
		if !testing.expect(t, integer) { continue }
		actual, conversion_error := big.int_get_i64(&value)
		testing.expectf(t, conversion_error == nil && actual == expected.value, "%s: %d", expected.name, actual)
	}
	for declaration in collection.declarations {
		name := entity_get(&scopes, declaration.entity).name
		if name != "runtime_maximum" && name != "info" && name != "info_dynamic" { continue }
		view, view_error := expression_file_view(&checker, 1)
		if !testing.expect(t, view_error == nil) { return }
		value := declaration.value.node
		info := Expression_Info {
			plan = checker.views[view].nodes.plans[value],
		}
		if !testing.expect(t, info.plan != 0) { continue }
		#partial switch plan in checker.plans[info.plan] {
		case Builtin_Plan:
			testing.expect(t, name == "runtime_maximum" && len(plan.arguments) == 4)
		case Type_Info_Plan:
			testing.expect(t, name == "info" && plan.table != 0 && plan.type != 0)
		case Call_Plan:
			testing.expect(t, name == "info_dynamic" && len(plan.arguments) == 1)
		case:
			testing.expect(t, false, "unexpected builtin plan")
		}
	}
	testing.expect_value(t, len(checker.diagnostics), 4)
}

package check

import "core:math/big"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
bit_ops_and_type_queries_fold_and_validate :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Record :: struct { value: u32 }
Flag :: enum { A, B }
numeric_enum_yes :: type_is_numeric(Flag) && type_is_numeric([2]Flag)
array_yes :: type_is_array([4]u8)
array_no :: type_is_array([]u8)
integer_yes :: type_is_integer(i64)
unsigned_no :: type_is_unsigned(i64)
pointer_yes :: type_is_internally_pointer_like(rawptr)
fields :: type_struct_field_count(Record)
has_value :: type_has_field(Record, "value")
missing_value :: type_has_field(Record, "missing")
Field :: type_field_type(Record, "value")
Element :: type_elem_type([4]u8)
Backing :: type_bit_set_underlying_type(bit_set[Flag])
upper :: saturating_add(u8(240), 30)
lower :: saturating_sub(i8(-120), 30)
bad_query :: type_is_array(42)
bad_field :: type_field_type(Record, "missing")
bad_saturation :: saturating_add(1, 2)
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
	for name in ([]string{"type_is_numeric", "type_is_array", "type_is_integer", "type_is_unsigned", "type_is_internally_pointer_like", "type_struct_field_count", "type_has_field", "type_field_type", "type_elem_type", "type_bit_set_underlying_type", "saturating_add", "saturating_sub"}) {
		builtin, failure := expression_builtin_id(&checker, intrinsic_builtin_kind(name))
		id, creation := entity_create(&scopes, Entity{name = name, kind = .Builtin, scope = universe, state = .Resolved, data = builtin})
		_, insertion := scope_insert(&scopes, universe, id)
		if !testing.expect(t, failure == nil && creation == nil && insertion == nil) { return }
	}
	for declaration in collection.declarations {
		state, failure := resolve_entity(&resolver, declaration.entity)
		name := entity_get(&scopes, declaration.entity).name
		invalid := name == "bad_query" || name == "bad_field" || name == "bad_saturation"
		testing.expectf(t, failure == nil && (state == .Invalid) == invalid, "%s: %v %v", name, state, failure)
	}
	for name in ([]string{"numeric_enum_yes", "array_yes", "integer_yes", "pointer_yes", "has_value"}) {
		entity := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, name))
		constant := constant_pool_get(&pool, entity.constant)
		if testing.expectf(t, constant != nil, "%s", name) { testing.expect(t, constant.value.(bool)) }
	}
	for name in ([]string{"array_no", "unsigned_no", "missing_value"}) {
		entity := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, name))
		constant := constant_pool_get(&pool, entity.constant)
		if testing.expectf(t, constant != nil, "%s", name) { testing.expect(t, !constant.value.(bool)) }
	}
	for expected in ([]struct {
			name: string,
			type: types.Type_Id,
		}{{"Field", builtin_types.u32}, {"Element", builtin_types.u8}, {"Backing", builtin_types.u8}}) {
		entity := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, expected.name))
		testing.expectf(t, entity.kind == .Type_Name && entity.type == expected.type, "%s", expected.name)
	}
	for expected in ([]struct {
			name:  string,
			value: i64,
		}{{"fields", 1}, {"upper", 255}, {"lower", -128}}) {
		entity := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, expected.name))
		constant := constant_pool_get(&pool, entity.constant)
		if !testing.expectf(t, constant != nil, "%s", expected.name) { continue }
		integer := constant.value.(big.Int)
		actual, failure := big.int_get_i64(&integer)
		testing.expectf(t, failure == nil && actual == expected.value, "%s: %d", expected.name, actual)
	}
}

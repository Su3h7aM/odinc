package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
constant_boxed_into_any_keeps_the_constant_source :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
take :: proc (slot: any) {}
main :: proc() {
	take(1)
}
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
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	any_type := types.intern(&store, types.Type{kind = .Any})
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
	any_id, any_create_error := entity_create(&scopes, Entity{name = "any", kind = .Type_Name, scope = universe, state = .Resolved, type = any_type})
	_, any_insert_error := scope_insert(&scopes, universe, any_id)
	if !testing.expect(t, any_create_error == nil && any_insert_error == nil) { return }
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
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
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		if !testing.expectf(t, err == nil && state == .Resolved, "%v %v", state, err) { return }
	}
	if !testing.expect(t, len(checker.diagnostics) == 0) { return }
	take_entity := scope_lookup_current(&scopes, package_scope, "take")
	if !testing.expect(t, take_entity != 0) { return }
	argument_found := false
	for plan in checker.plans {
		call, is_call := plan.(Call_Plan)
		if !is_call || call.entity != take_entity { continue }
		if !testing.expect(t, len(call.arguments) == 1) { return }
		argument_found = true
		argument := call.arguments[0]
		conversion, is_conversion := checker.plans[argument.conversion].(Conversion_Plan)
		if !testing.expect(t, is_conversion && conversion.kind == .Box && conversion.target == any_type) { return }
		source, is_constant := conversion.source.(Const_Id)
		if !testing.expect(t, is_constant, "a constant boxed into any keeps its constant as the conversion source") { return }
		constant := constant_pool_get(checker.constants, source)
		if !testing.expect(t, constant != nil && constant.type == integer) { return }
		testing.expect(t, argument.value == Operand(source), "the argument names the same constant the conversion boxes")
	}
	testing.expect(t, argument_found, "expected one call to take")
}

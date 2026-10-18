package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
proc_group_call_resolves_member_by_argument_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
first :: proc "contextless" (value: int) -> int { return value }
second :: proc "contextless" (value: f64) -> f64 { return value }
poly :: proc "contextless" (value: $T) -> T { return value }
pick :: proc{first, second}
pick_generic :: proc{poly, second}
whole :: proc "contextless" (value: $T) -> int { return 1 }
sliced :: proc "contextless" (value: $T/[]$E) -> int { return 2 }
pick_slice :: proc{whole, sliced}
defaulted :: proc "contextless" (value: $T, extra := 2) -> int { return 3 }
with_bool :: proc "contextless" (value: $T, extra: bool) -> int { return 4 }
pick_defaulted :: proc{defaulted, with_bool}
fixed :: proc "contextless" (value: int) -> int { return value }
repeated :: proc (value: int, rest: ..int) -> int { return value }
pick_variadic :: proc{fixed, repeated}
variadic_choice := pick_variadic(1, 2, 3)
integer_choice := pick(3)
float_choice := pick(2.5)
integer_value: int
generic_choice := pick_generic(integer_value)
integer_slice: []int
slice_choice := pick_slice(integer_slice)
defaulted_choice := pick_defaulted(1)
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
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
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
	float := types.intern(&store, types.Type{kind = .Float, count = 8})
	for named in ([?]struct {
			name: string,
			type: types.Type_Id,
		}{{"int", integer}, {"f64", float}}) {
		id, create_error := entity_create(&scopes, Entity{name = named.name, kind = .Type_Name, scope = universe, state = .Resolved, type = named.type})
		_, insert_error := scope_insert(&scopes, universe, id)
		if !testing.expect(t, create_error == nil && insert_error == nil) { return }
	}
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
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		name := entity_get(&scopes, declaration.entity).name
		if !testing.expectf(t, err == nil && state == .Resolved, "%s: %v %v", name, state, err) { return }
	}
	testing.expect(t, len(checker.diagnostics) == 0)
	view, view_error := expression_file_view(&checker, 1)
	if !testing.expect(t, view_error == nil) { return }
	for declaration in collection.declarations {
		name := entity_get(&scopes, declaration.entity).name
		call, is_call := checker.plans[checker.views[view].nodes.plans[declaration.value.node]].(Call_Plan)
		switch name {
		case "integer_choice":
			testing.expect(t, is_call && call.entity == scope_lookup_current(&scopes, package_scope, "first"))
		case "variadic_choice":
			testing.expect(t, is_call && call.entity == scope_lookup_current(&scopes, package_scope, "repeated"))
		case "float_choice":
			testing.expect(t, is_call && call.entity == scope_lookup_current(&scopes, package_scope, "second"))
		case "generic_choice":
			if !testing.expect(t, is_call) { continue }
			procedure, is_procedure := entity_get(&scopes, call.entity).data.(Procedure_Data)
			testing.expect(t, is_procedure && procedure.definition == scope_lookup_current(&scopes, package_scope, "poly"))
		case "slice_choice":
			if !testing.expect(t, is_call) { continue }
			procedure, is_procedure := entity_get(&scopes, call.entity).data.(Procedure_Data)
			testing.expect(t, is_procedure && procedure.definition == scope_lookup_current(&scopes, package_scope, "sliced"))
		case "defaulted_choice":
			if !testing.expect(t, is_call) { continue }
			procedure, is_procedure := entity_get(&scopes, call.entity).data.(Procedure_Data)
			testing.expect(t, is_procedure && procedure.definition == scope_lookup_current(&scopes, package_scope, "defaulted"))
		}
	}
}


@(test)
proc_group_where_conditions_filter_members :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
first :: proc "contextless" (value: int) -> int { return value }
second :: proc "contextless" (value: f64) -> f64 { return value }
poly :: proc "contextless" (value: $T) -> T { return value }
pick :: proc{first where false, second where true}
pick_generic :: proc{poly, second}
whole :: proc "contextless" (value: $T) -> int { return 1 }
sliced :: proc "contextless" (value: $T/[]$E) -> int { return 2 }
pick_slice :: proc{whole, sliced}
defaulted :: proc "contextless" (value: $T, extra := 2) -> int { return 3 }
with_bool :: proc "contextless" (value: $T, extra: bool) -> int { return 4 }
pick_defaulted :: proc{defaulted, with_bool}
integer_choice := pick(2.5)
float_choice := pick(2.5)
integer_value: int
generic_choice := pick_generic(integer_value)
integer_slice: []int
slice_choice := pick_slice(integer_slice)
defaulted_choice := pick_defaulted(1)
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
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
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
	float := types.intern(&store, types.Type{kind = .Float, count = 8})
	for named in ([?]struct {
			name: string,
			type: types.Type_Id,
		}{{"int", integer}, {"f64", float}}) {
		id, create_error := entity_create(&scopes, Entity{name = named.name, kind = .Type_Name, scope = universe, state = .Resolved, type = named.type})
		_, insert_error := scope_insert(&scopes, universe, id)
		if !testing.expect(t, create_error == nil && insert_error == nil) { return }
	}
	for value in ([]bool{false, true}) {
		constant, constant_error := constant_pool_intern_bool(&pool, value, types.TYPE_UNTYPED_BOOL)
		name := "true" if value else "false"
		id, create_error := entity_create(
			&scopes,
			Entity{name = name, kind = .Constant, scope = universe, state = .Resolved, type = types.TYPE_UNTYPED_BOOL, constant = constant},
		)
		_, insert_error := scope_insert(&scopes, universe, id)
		if !testing.expect(t, constant_error == nil && create_error == nil && insert_error == nil) { return }
	}
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
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		name := entity_get(&scopes, declaration.entity).name
		if !testing.expectf(t, err == nil && state == .Resolved, "%s: %v %v", name, state, err) { return }
	}
	testing.expect(t, len(checker.diagnostics) == 0)
	view, view_error := expression_file_view(&checker, 1)
	if !testing.expect(t, view_error == nil) { return }
	for declaration in collection.declarations {
		name := entity_get(&scopes, declaration.entity).name
		call, is_call := checker.plans[checker.views[view].nodes.plans[declaration.value.node]].(Call_Plan)
		switch name {
		case "integer_choice":
			testing.expect(t, is_call && call.entity == scope_lookup_current(&scopes, package_scope, "second"))
		case "float_choice":
			testing.expect(t, is_call && call.entity == scope_lookup_current(&scopes, package_scope, "second"))
		case "generic_choice":
			if !testing.expect(t, is_call) { continue }
			procedure, is_procedure := entity_get(&scopes, call.entity).data.(Procedure_Data)
			testing.expect(t, is_procedure && procedure.definition == scope_lookup_current(&scopes, package_scope, "poly"))
		case "slice_choice":
			if !testing.expect(t, is_call) { continue }
			procedure, is_procedure := entity_get(&scopes, call.entity).data.(Procedure_Data)
			testing.expect(t, is_procedure && procedure.definition == scope_lookup_current(&scopes, package_scope, "sliced"))
		case "defaulted_choice":
			if !testing.expect(t, is_call) { continue }
			procedure, is_procedure := entity_get(&scopes, call.entity).data.(Procedure_Data)
			testing.expect(t, is_procedure && procedure.definition == scope_lookup_current(&scopes, package_scope, "defaulted"))
		}
	}
}

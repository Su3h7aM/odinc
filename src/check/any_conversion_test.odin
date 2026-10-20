package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
any_declarations_assignments_and_returns_record_boxing_conversions :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	value: int
	boxed: any = value
	asserted, ok := boxed.(int)
	single := boxed.(int)
	data := boxed.data
	id := boxed.id
	slot: any
	slot, _ = value, 0
}
give :: proc "contextless" (value: int) -> any {
	return value
}
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
	int_id, int_create_error := entity_create(&scopes, Entity{name = "int", kind = .Type_Name, scope = universe, state = .Resolved, type = integer})
	_, int_insert_error := scope_insert(&scopes, universe, int_id)
	if !testing.expect(t, any_create_error == nil && any_insert_error == nil && int_create_error == nil && int_insert_error == nil) { return }
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
		testing.expectf(t, err == nil && state == .Resolved, "%v %v", state, err)
	}
	main := entity_get(&scopes, collection.declarations[0].entity)
	procedure := main.data.(Procedure_Data)
	testing.expect(t, procedure.body_state == .Complete)
	body := syntax.node_payload(&ast, procedure.body.node, syntax.Block_Stmt)
	statements := syntax.node_list(&ast, body.stmts)
	program: Checked_Program
	expression_checker_publish(&checker, &program)
	program.files = []File{{}, file}
	boxing_count := 0
	for plan in program.plan_table {
		if conversion, is_conversion := plan.(Conversion_Plan); is_conversion && conversion.kind == .Box { boxing_count += 1 }
	}
	testing.expectf(t, boxing_count == 3, "three boxing sites created %d conversion plans", boxing_count)
	assertion := syntax.node_payload(&ast, statements[2], syntax.Value_Decl)
	assertion_rhs := syntax.node_list(&ast, assertion.values)[0]
	assertion_info, assertion_found := expression_info(&program, 1, assertion_rhs)
	assertion_plan, is_assertion := program.plan_table[assertion_info.plan].(Type_Assertion_Plan)
	testing.expect(
		t,
		assertion_found && assertion_info.mode == .Optional_Ok && is_assertion && assertion_plan.target_type == integer && assertion_plan.comma_ok,
	)
	single_declaration := syntax.node_payload(&ast, statements[3], syntax.Value_Decl)
	single_expression := syntax.node_list(&ast, single_declaration.values)[0]
	single_info, single_found := expression_info(&program, 1, single_expression)
	single_plan, is_single_assertion := program.plan_table[single_info.plan].(Type_Assertion_Plan)
	testing.expect(t, single_found && is_single_assertion && !single_plan.comma_ok)
	data_declaration := syntax.node_payload(&ast, statements[4], syntax.Value_Decl)
	data_expression := syntax.node_list(&ast, data_declaration.values)[0]
	data_info, data_found := expression_info(&program, 1, data_expression)
	data_place, data_is_place := program.plan_table[data_info.plan].(Place_Plan)
	testing.expect(t, data_found && data_is_place && len(data_place.path) == 1 && data_place.path[0].field_index == 0)
	id_declaration := syntax.node_payload(&ast, statements[5], syntax.Value_Decl)
	id_expression := syntax.node_list(&ast, id_declaration.values)[0]
	id_info, id_found := expression_info(&program, 1, id_expression)
	id_place, id_is_place := program.plan_table[id_info.plan].(Place_Plan)
	testing.expect(t, id_found && id_is_place && len(id_place.path) == 1 && id_place.path[0].field_index == 1)
	declaration_info, declaration_found := expression_info(&program, 1, statements[1])
	declared, is_declared := program.plan_table[declaration_info.plan].(Assignment_Plan)
	testing.expect(t, declaration_found && is_declared && len(declared.conversions) == 1 && declared.conversions[0] != 0)
	if is_declared && declared.conversions[0] != 0 {
		conversion, is_conversion := program.plan_table[declared.conversions[0]].(Conversion_Plan)
		testing.expect(t, is_conversion && conversion.kind == .Box && conversion.target == any_type)
	}
	assignment_info, assignment_found := expression_info(&program, 1, statements[7])
	assigned, is_assigned := program.plan_table[assignment_info.plan].(Assignment_Plan)
	testing.expect(t, assignment_found && is_assigned && assigned.conversions[0] != 0)
	give := entity_get(&scopes, collection.declarations[1].entity).data.(Procedure_Data)
	give_body := syntax.node_payload(&ast, give.body.node, syntax.Block_Stmt)
	return_info, return_found := expression_info(&program, 1, syntax.node_list(&ast, give_body.stmts)[0])
	exit, is_exit := program.plan_table[return_info.plan].(Exit_Plan)
	testing.expect(t, return_found && is_exit && len(exit.conversions) == 1 && exit.conversions[0] != 0)
}

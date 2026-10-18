package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
procedures_record_zero_parameter_signatures :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
global_uninitialized: u8 = ---
main :: proc "contextless" () {
	buffer: [6]u8
	value: u8
	index := 1
	value = 7
	buffer[5] = '\n'
	#no_bounds_check unchecked := buffer[index]
	checked := buffer[index]
	#no_bounds_check for i in 0 ..< 5 {
		buffer[i] = u8('a' + i)
	}
	pointer := cast([^]u8)&buffer[0]
	pointer = pointer[1:]
	slice := pointer[1:3]
	uninitialized: u8 = ---
	zeroed: u8
}
invalid_inferred :: proc "contextless" () {
	value := ---
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
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
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
	byte_id, byte_create_error := entity_create(&scopes, Entity{name = "u8", kind = .Type_Name, scope = universe, state = .Resolved, type = byte_type})
	_, byte_insert_error := scope_insert(&scopes, universe, byte_id)
	if !testing.expect(t, byte_create_error == nil && byte_insert_error == nil) { return }
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
		_, err := resolve_entity(&resolver, declaration.entity)
		testing.expect_value(t, err, nil)
	}
	main_id := scope_lookup_current(&scopes, package_scope, "main")
	main := entity_get(&scopes, main_id)
	procedure := main.data.(Procedure_Data)
	testing.expect(t, procedure.signature != 0 && procedure.signature == main.type)
	testing.expect(t, types.get(&store, procedure.signature).kind == .Procedure && len(types.get(&store, procedure.signature).params) == 0)
	testing.expect(t, procedure.body_state == .Complete)
	body := syntax.node_payload(&ast, procedure.body.node, syntax.Block_Stmt)
	local := syntax.node_payload(&ast, syntax.node_list(&ast, body.stmts)[0], syntax.Value_Decl)
	program: Checked_Program
	expression_checker_publish(&checker, &program)
	program.files = []File{{}, file}
	info, found := expression_info(&program, 1, syntax.node_list(&ast, local.names)[0])
	testing.expect(t, found && info.mode == .Variable && types.get(&store, info.type).count == 6)
	assignment_info, assignment_found := expression_info(&program, 1, syntax.node_list(&ast, body.stmts)[3])
	assignment, is_assignment := program.plan_table[assignment_info.plan].(Assignment_Plan)
	testing.expect(t, assignment_found && is_assignment && len(assignment.destinations) == 1 && assignment.conversions[0] != 0)
	indexed_assignment := syntax.node_payload(&ast, syntax.node_list(&ast, body.stmts)[4], syntax.Assign_Stmt)
	indexed, indexed_found := expression_info(&program, 1, syntax.node_list(&ast, indexed_assignment.lhs)[0])
	bounds, is_bounds := program.plan_table[indexed.plan].(Bounds_Plan)
	testing.expect(t, indexed_found && indexed.mode == .Variable && is_bounds && bounds.policy == .Disabled && len(bounds.operands) == 2)
	loop := syntax.node_payload(&ast, syntax.node_list(&ast, body.stmts)[7], syntax.Range_Stmt)
	loop_body := syntax.node_payload(&ast, loop.body, syntax.Block_Stmt)
	inner := syntax.node_payload(&ast, syntax.node_list(&ast, loop_body.stmts)[0], syntax.Assign_Stmt)
	inside, inside_found := expression_info(&program, 1, syntax.node_list(&ast, inner.lhs)[0])
	unchecked, is_unchecked := program.plan_table[inside.plan].(Bounds_Plan)
	testing.expect(t, inside_found && is_unchecked && unchecked.policy == .Disabled)
	unchecked_decl := syntax.node_payload(&ast, syntax.node_list(&ast, body.stmts)[5], syntax.Value_Decl)
	unchecked_value := syntax.node_list(&ast, unchecked_decl.values)[0]
	unchecked_info, unchecked_found := expression_info(&program, 1, unchecked_value)
	unchecked_plan, is_unchecked_plan := program.plan_table[unchecked_info.plan].(Bounds_Plan)
	testing.expect(t, unchecked_found && is_unchecked_plan && unchecked_plan.policy == .Disabled)
	checked_decl := syntax.node_payload(&ast, syntax.node_list(&ast, body.stmts)[6], syntax.Value_Decl)
	checked_value := syntax.node_list(&ast, checked_decl.values)[0]
	checked_info, checked_found := expression_info(&program, 1, checked_value)
	checked_plan, is_checked_plan := program.plan_table[checked_info.plan].(Bounds_Plan)
	testing.expect(t, checked_found && is_checked_plan && checked_plan.policy == .Enabled)
	statements := syntax.node_list(&ast, body.stmts)
	uninitialized_info, uninitialized_found := expression_info(&program, 1, statements[11])
	uninitialized_plan, is_uninitialized_plan := program.plan_table[uninitialized_info.plan].(Assignment_Plan)
	testing.expect(
		t,
		uninitialized_found && is_uninitialized_plan && len(uninitialized_plan.initializes) == 1 && !uninitialized_plan.initializes[0],
		"typed --- declaration must record that it skips initialization",
	)
	invalid_entity := scope_lookup_current(&scopes, package_scope, "invalid_inferred")
	invalid_procedure := entity_get(&scopes, invalid_entity).data.(Procedure_Data)
	testing.expect(t, invalid_procedure.body_state == .Invalid, "inferred --- declaration must be rejected")
	testing.expect(t, len(checker.diagnostics) >= 2, "global and inferred --- declarations must be rejected")
	pointer_decl := syntax.node_payload(&ast, statements[8], syntax.Value_Decl)
	pointer_id := syntax.node_list(&ast, pointer_decl.names)[0]
	pointer_info, pointer_found := expression_info(&program, 1, pointer_id)
	testing.expect(t, pointer_found && types.get(&store, pointer_info.type).kind == .Multi_Pointer)
	pointer_assignment := syntax.node_payload(&ast, statements[9], syntax.Assign_Stmt)
	pointer_slice := syntax.node_list(&ast, pointer_assignment.rhs)[0]
	pointer_slice_info, pointer_slice_found := expression_info(&program, 1, pointer_slice)
	testing.expect(t, pointer_slice_found && pointer_slice_info.type == pointer_info.type)
	slice_decl := syntax.node_payload(&ast, statements[10], syntax.Value_Decl)
	slice_value := syntax.node_list(&ast, slice_decl.values)[0]
	slice_info, slice_found := expression_info(&program, 1, slice_value)
	testing.expect(t, slice_found && types.get(&store, slice_info.type).kind == .Slice)
}

@(test)
invalid_local_initializer_keeps_its_name_declared :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	value := !"s"
	if value != 0 { value = 1 }
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operator, "", 1)
	testing.expect(t, ok)
}

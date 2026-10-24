package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
syscall_program_checks_section_19_source :: proc(t: ^testing.T) {
	main_source := transmute([]byte)string(
		`package main

import "base:intrinsics"

main :: proc() {
	buffer: [6]u8
	#no_bounds_check for i in 0 ..< 5 {
		buffer[i] = u8('a' + i)
	}
	buffer[5] = '\n'
	intrinsics.syscall(1, 1, uintptr(&buffer), 6)
	intrinsics.syscall(60, 0)
	#assert(intrinsics.type_is_integer(uintptr))
}
unknown_intrinsic :: proc() { intrinsics.not_a_real_intrinsic() }
`,
	)
	main_ast: syntax.Ast
	syntax.ast_init(&main_ast, context.allocator)
	defer syntax.ast_destroy(&main_ast)
	main_parser: syntax.Parser
	syntax.parser_init(&main_parser, &main_ast, main_source, context.allocator)
	defer syntax.parser_destroy(&main_parser)
	syntax.parse_file(&main_parser)
	if !testing.expect(t, len(main_parser.errors) + len(main_parser.lex_errors) == 0) { return }
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return }
	defer scope_store_destroy(&scopes)
	universe, universe_error := scope_create(&scopes, 0, .Universal)
	main_package, main_package_error := scope_create(&scopes, universe, .Package)
	main_file_scope, main_file_error := scope_create(&scopes, main_package, .File)
	intrinsics_package, intrinsics_package_error := scope_create(&scopes, universe, .Package)
	if !testing.expect(t, universe_error == nil && main_package_error == nil && main_file_error == nil && intrinsics_package_error == nil) { return }
	if !testing.expect(t, intrinsic_scope_init(&scopes, intrinsics_package, 2) == nil) { return }
	for builtin in ([]struct {
			name: string,
			type: types.Type_Id,
		}{{"u8", byte_type}, {"uintptr", word}}) {
		id, create_error := entity_create(&scopes, Entity{name = builtin.name, kind = .Type_Name, scope = universe, state = .Resolved, type = builtin.type})
		_, insert_error := scope_insert(&scopes, universe, id)
		if !testing.expect(t, create_error == nil && insert_error == nil) { return }
	}
	main_file := File {
		package_id = 1,
		ast        = &main_ast,
		source     = main_source,
		scope      = main_file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	if !testing.expect(t, collect_file(&collection, &main_file, 1, {}) == nil) { return }
	if !testing.expect(t, collect_import_name(&collection, &main_file, 0, "intrinsics", 2) == nil && len(collection.diagnostics) == 0) { return }
	checker: Expression_Checker
	resolver: Resolver
	resolver_init(&resolver, &scopes, expression_declaration, &checker, context.allocator)
	defer resolver_destroy(&resolver)
	type_checker: Type_Checker
	type_checker_init(&type_checker, &resolver, &collection, &store, []^File{nil, &main_file}, expression_integer_evaluator, &checker, context.allocator)
	defer type_checker_destroy(&type_checker)
	if !testing.expect(
		t,
		expression_checker_init(&checker, &type_checker, &pool, {uintptr = word, layout = types.DEFAULT_LAYOUT}, integer, boolean, context.allocator) == nil,
	) { return }
	defer expression_checker_destroy(&checker)
	checker.packages = []Package {
		{},
		{name = "main", kind = .User, scope = main_package},
		{name = "intrinsics", kind = .Intrinsics, scope = intrinsics_package},
	}
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		testing.expectf(
			t,
			err == nil && state == .Resolved,
			"%s %v %v %d %d %d",
			entity_get(&scopes, declaration.entity).name,
			state,
			err,
			len(type_checker.diagnostics),
			len(checker.diagnostics),
			len(resolver.diagnostics),
		)
	}
	testing.expect(t, len(type_checker.diagnostics) == 0 && len(resolver.diagnostics) == 0 && len(checker.diagnostics) == 1)
	if len(checker.diagnostics) == 1 { testing.expect_value(t, checker.diagnostics[0].reason, "'not_a_real_intrinsic' is not declared by 'intrinsics'") }
	main := entity_get(&scopes, scope_lookup_current(&scopes, main_package, "main"))
	procedure := main.data.(Procedure_Data)
	testing.expect(t, procedure.body_state == .Complete)
	body := syntax.node_payload(&main_ast, procedure.body.node, syntax.Block_Stmt)
	statements := syntax.node_list(&main_ast, body.stmts)
	program: Checked_Program
	expression_checker_publish(&checker, &program)
	program.files = []File{{}, main_file}
	call := syntax.node_payload(&main_ast, statements[3], syntax.Expr_Stmt).expr
	call_info, call_found := expression_info(&program, 1, call)
	plan, is_builtin := program.plan_table[call_info.plan].(Builtin_Plan)
	testing.expect(t, call_found && is_builtin && len(plan.arguments) == 4 && program.builtin_kinds[plan.builtin] == .Syscall)
	address := syntax.node_list(&main_ast, syntax.node_payload(&main_ast, call, syntax.Call_Expr).args)[2]
	address_info, address_found := expression_info(&program, 1, address)
	testing.expect(t, address_found && address_info.type == word)
	pointer := syntax.node_list(&main_ast, syntax.node_payload(&main_ast, address, syntax.Call_Expr).args)[0]
	pointer_info, pointer_found := expression_info(&program, 1, pointer)
	testing.expect(t, pointer_found && types.get(&store, pointer_info.type).kind == .Pointer)
}

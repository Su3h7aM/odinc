package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
declaration_cycles_allow_identity_references_and_finish_layouts :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Tool_Execute :: #type proc(ctx: ^Tool_Context, args: Tool_Args) -> Tool_Result
Tool_Context :: struct { background: ^Background_Jobs }
Background_Jobs :: struct { jobs: [dynamic]^Tool_Job }
Tool_Job :: struct { execute: Tool_Execute }
Tool_Args :: struct {}
Tool_Result :: struct {}
Tool_Execute_Union :: union { proc(ctx: ^Tool_Context, args: Tool_Args) -> Tool_Result }
Index :: enum { First, Second }
Index_Array :: [Index]string
Parenthesized_Index_Array :: [(Index)]string
Qualified_Index_Array :: [other.Index]string
Node_Pointer :: ^Node
Node :: struct { next: Node_Pointer }
Arena :: struct { last: ^Allocation }
Base_Allocation :: struct { previous: ^Allocation }
Allocation :: Base_Allocation
`,
	)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expect(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0) { return }

	type_store := types.init()
	defer types.destroy(&type_store)
	store: Scope_Store
	if !testing.expect(t, scope_store_init(&store, context.allocator) == nil) { return }
	defer scope_store_destroy(&store)
	universe, universe_err := scope_create(&store, 0, .Universal)
	package_scope, package_err := scope_create(&store, universe, .Package)
	file_scope, file_err := scope_create(&store, package_scope, .File)
	if !testing.expect(t, universe_err == nil && package_err == nil && file_scope != 0 && file_err == nil) { return }
	other_package_scope, other_package_error := scope_create(&store, universe, .Package)
	if !testing.expect(t, other_package_error == nil && other_package_scope != 0) { return }
	string_type := types.intern(&type_store, types.Type{kind = .String})
	string_id, string_create_error := entity_create(
		&store,
		Entity{name = "string", kind = .Type_Name, scope = universe, state = .Resolved, type = string_type},
	)
	_, string_insert_error := scope_insert(&store, universe, string_id)
	if !testing.expect(t, string_create_error == nil && string_insert_error == nil) { return }
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &store, context.allocator)
	defer collection_destroy(&collection)
	if !testing.expect(t, collect_file(&collection, &file, 1, {}) == nil && len(collection.diagnostics) == 0) { return }

	data: Declaration_Cycle_Test_Data
	resolver: Resolver
	resolver_init(&resolver, &store, declaration_cycle_test_resolver, &data, context.allocator)
	defer resolver_destroy(&resolver)
	files := []^File{nil, &file}
	type_checker_init(&data.checker, &resolver, &collection, &type_store, files, nil, nil, context.allocator)
	defer type_checker_destroy(&data.checker)
	data.checker.packages = []Package{{}, {scope = package_scope}, {scope = other_package_scope}}
	import_id, import_error := entity_create(
		&store,
		Entity{name = "other", kind = .Import_Name, scope = file_scope, state = .Resolved, data = Import_Data{package_id = 2}},
	)
	_, import_insert_error := scope_insert(&store, file_scope, import_id)
	if !testing.expect(t, import_error == nil && import_insert_error == nil) { return }
	index_id := scope_lookup_current(&store, package_scope, "Index")
	index_state, index_error := resolve_entity(&resolver, index_id)
	other_index_id, other_index_error := entity_create(
		&store,
		Entity{name = "Index", kind = .Type_Name, scope = other_package_scope, state = .Resolved, type = entity_get(&store, index_id).type},
	)
	_, other_index_insert_error := scope_insert(&store, other_package_scope, other_index_id)
	if !testing.expect(t, index_error == nil && index_state == .Resolved && other_index_error == nil && other_index_insert_error == nil) { return }

	for name in ([]string{"Tool_Execute", "Tool_Context", "Background_Jobs", "Tool_Job", "Tool_Execute_Union", "Index_Array", "Parenthesized_Index_Array", "Qualified_Index_Array", "Node_Pointer", "Node", "Arena", "Base_Allocation", "Allocation"}) {
		id := scope_lookup_current(&store, package_scope, name)
		state, resolve_error := resolve_entity(&resolver, id)
		if !testing.expectf(
			t,
			resolve_error == nil && state == .Resolved && entity_get(&store, id).state == .Resolved,
			"%s: %v %v",
			name,
			state,
			resolve_error,
		) { return }
	}
	if !testing.expect(t, len(resolver.diagnostics) == 0 && check_nominal_layouts(&data.checker) == nil) { return }

	execute_id := entity_get(&store, scope_lookup_current(&store, package_scope, "Tool_Execute")).type
	execute_type := types.get(&type_store, execute_id)
	structural_procedure := types.intern(&type_store, execute_type^)
	if !testing.expect(
		t,
		execute_type.kind == .Procedure && !execute_type.is_nominal && types.are_identical(&type_store, execute_id, structural_procedure),
	) { return }
	execute_union_id := entity_get(&store, scope_lookup_current(&store, package_scope, "Tool_Execute_Union")).type
	execute_union := types.get(&type_store, execute_union_id)
	if !testing.expect(t, execute_union.kind == .Union && len(execute_union.variants) == 1) { return }
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	procedure_value := Expression_Info {
		type  = execute_id,
		mode  = .Value,
		state = .Checked,
	}
	_, conversion_diagnostic, conversion_error := check_conversion(
		&pool,
		&type_store,
		Operand(Expression_Ref{view = 1, node = 1}),
		procedure_value,
		execute_union.variants[0],
		.Assignment,
		{},
	)
	if !testing.expect(t, conversion_error == nil && conversion_diagnostic == .None) { return }
	context_id := entity_get(&store, scope_lookup_current(&store, package_scope, "Tool_Context")).type
	background_id := entity_get(&store, scope_lookup_current(&store, package_scope, "Background_Jobs")).type
	job_id := entity_get(&store, scope_lookup_current(&store, package_scope, "Tool_Job")).type
	for type_id in ([]types.Type_Id{execute_id, context_id, background_id, job_id}) {
		size, _, layout_error := types.layout(&type_store, type_id)
		if !testing.expectf(
			t,
			layout_error == .None && size > 0,
			"type %v (%v complete): %v, size %v",
			type_id,
			types.get(&type_store, type_id).is_complete,
			layout_error,
			size,
		) { return }
	}
	for type_id in ([]types.Type_Id{context_id, background_id, job_id}) {
		offset, offset_error := types.field_offset(&type_store, type_id, 0)
		if !testing.expect(t, offset_error == .None && offset == 0) { return }
	}
	for name in ([]string{"Index_Array", "Parenthesized_Index_Array", "Qualified_Index_Array"}) {
		array := types.get(&type_store, entity_get(&store, scope_lookup_current(&store, package_scope, name)).type)
		if !testing.expect(t, array.kind == .Enumerated_Array && array.count == 2) { return }
	}
}

Declaration_Cycle_Test_Data :: struct {
	checker: Type_Checker,
}

declaration_cycle_test_resolver :: proc(resolver: ^Resolver, id: Entity_Id, user_data: rawptr) -> (valid: bool, err: Resolve_Error) {
	data := (^Declaration_Cycle_Test_Data)(user_data)
	_, valid, err = type_declaration(&data.checker, id)
	return
}

package check

import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
declaration_cycles_allow_incomplete_pointer_and_procedure_types :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Tool_Execute :: #type proc(ctx: ^Tool_Context, args: Tool_Args) -> Tool_Result
Tool_Context :: struct { background: ^Background_Jobs }
Background_Jobs :: struct { jobs: [dynamic]^Tool_Job }
Tool_Job :: struct { execute: Tool_Execute }
Tool_Args :: struct {}
Tool_Result :: struct {}
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

	data: Type_Cycle_Test_Data
	resolver: Resolver
	resolver_init(&resolver, &store, type_cycle_test_resolver, &data, context.allocator)
	defer resolver_destroy(&resolver)
	files := []^File{nil, &file}
	type_checker_init(&data.checker, &resolver, &collection, &type_store, files, nil, nil, context.allocator)
	defer type_checker_destroy(&data.checker)

	id := scope_lookup_current(&store, package_scope, "Tool_Execute")
	state, resolve_error := resolve_entity(&resolver, id)
	if !testing.expect(t, resolve_error == nil && state == .Resolved && len(resolver.diagnostics) == 0) { return }
	for name in ([]string{"Tool_Context", "Background_Jobs", "Tool_Job"}) {
		id = scope_lookup_current(&store, package_scope, name)
		state, resolve_error = resolve_entity(&resolver, id)
		if !testing.expect(t, resolve_error == nil && state == .Resolved) { return }
		entity := entity_get(&store, id)
		if !testing.expect(t, entity.state == .Resolved && entity.type != types.TYPE_POISON && types.get(&type_store, entity.type).is_complete) { return }
	}
	if !testing.expect(t, check_nominal_layouts(&data.checker) == nil) { return }
}

Type_Cycle_Test_Data :: struct {
	checker: Type_Checker,
}

type_cycle_test_resolver :: proc(resolver: ^Resolver, id: Entity_Id, user_data: rawptr) -> (valid: bool, err: Resolve_Error) {
	data := (^Type_Cycle_Test_Data)(user_data)
	handled: bool
	handled, valid, err = type_declaration(&data.checker, id)
	return valid, err
}

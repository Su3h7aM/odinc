package check

import "core:strconv"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(private = "file")
Type_Test_Data :: struct {
	checker: Type_Checker,
	integer: types.Type_Id,
}

@(test)
type_expressions_resolve_recursive_nominals_and_report_errors :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Count :: 3
Color :: enum u8 { Red, Green = 5, Blue }
Node :: struct { next: ^Node, value: int, tag: Color, items: [Count]int, list: []Node }
A :: struct { b: ^B }
B :: struct { a: A }
Handle :: distinct int
Alias :: ^Handle
Choice :: union { int, ^Node, bool }
Optional :: union { ^Node }
Callback :: proc "c" (int, Node) -> (value: int, ok: bool)
Table :: [Color]int
Names :: map[int][dynamic]Node
Spelling :: Handle
Bad :: struct { field: Missing }
Duplicate :: struct { a: int, a: int }
Direct :: struct { self: Direct }
Loop :: ^Loop
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
	integer := types.intern(&type_store, types.Type{kind = .Integer, count = 8, signed = true})
	byte_type := types.intern(&type_store, types.Type{kind = .Integer, count = 1})
	boolean := types.intern(&type_store, types.Type{kind = .Bool})

	store: Scope_Store
	if !testing.expect(t, scope_store_init(&store, context.allocator) == nil) { return }
	defer scope_store_destroy(&store)
	universe, universe_err := scope_create(&store, 0, .Universal)
	package_scope, package_err := scope_create(&store, universe, .Package)
	file_scope, file_err := scope_create(&store, package_scope, .File)
	if !testing.expect(t, universe_err == nil && package_err == nil && file_scope != 0 && file_err == nil) { return }
	builtins := []struct {
		name: string,
		type: types.Type_Id,
	}{{"int", integer}, {"u8", byte_type}, {"bool", boolean}}
	for builtin in builtins {
		id, create_err := entity_create(&store, Entity{name = builtin.name, kind = .Type_Name, scope = universe, state = .Resolved, type = builtin.type})
		_, insert_err := scope_insert(&store, universe, id)
		if !testing.expect(t, create_err == nil && insert_err == nil) { return }
	}
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

	data := Type_Test_Data {
		integer = integer,
	}
	resolver: Resolver
	resolver_init(&resolver, &store, test_type_resolver, &data, context.allocator)
	defer resolver_destroy(&resolver)
	files := []^File{nil, &file}
	type_checker_init(&data.checker, &resolver, &collection, &type_store, files, test_integer_evaluator, nil, context.allocator)
	defer type_checker_destroy(&data.checker)
	data.checker.user_data = &data

	names := []string {
		"Count",
		"Color",
		"Node",
		"A",
		"B",
		"Handle",
		"Alias",
		"Choice",
		"Optional",
		"Callback",
		"Table",
		"Names",
		"Spelling",
		"Bad",
		"Duplicate",
		"Direct",
		"Loop",
	}
	states: [17]Resolution_State
	for name, index in names {
		state, err := resolve_entity(&resolver, scope_lookup_current(&store, package_scope, name))
		testing.expect(t, err == nil)
		states[index] = state
	}
	for state, index in states {
		invalid := names[index] == "Bad" || names[index] == "Duplicate" || names[index] == "Loop"
		testing.expectf(t, (state == .Invalid) == invalid, "%s: %v", names[index], state)
	}
	testing.expect(t, check_nominal_layouts(&data.checker) == nil)

	lookup := proc(store: ^Scope_Store, scope: Scope_Id, name: string) -> ^Entity {
		return entity_get(store, scope_lookup_current(store, scope, name))
	}
	node := types.get(&type_store, lookup(&store, package_scope, "Node").type)
	if testing.expect(t, node.kind == .Struct && node.is_complete && len(node.fields) == 5) {
		testing.expect(
			t,
			types.get(&type_store, node.fields[0].type).kind == .Pointer &&
			types.get(&type_store, node.fields[0].type).elem == lookup(&store, package_scope, "Node").type,
		)
		array := types.get(&type_store, node.fields[3].type)
		testing.expect(t, array.kind == .Array && array.count == 3 && array.elem == integer)
		testing.expect(t, types.get(&type_store, node.fields[4].type).kind == .Slice)
		_, _, layout_err := types.layout(&type_store, lookup(&store, package_scope, "Node").type)
		testing.expect(t, layout_err == .None)
	}
	color_id := lookup(&store, package_scope, "Color").type
	color := types.get(&type_store, color_id)
	members := data.checker.enum_members[color_id]
	testing.expect(t, color.kind == .Enum && color.backing == byte_type && color.lower_bound == 0 && color.upper_bound == 6)
	if testing.expect(t, len(members) == 3) {
		testing.expect(t, members[0].name == "Red" && members[1].value == 5 && members[2].name == "Blue" && members[2].value == 6)
	}
	handle := types.get(&type_store, lookup(&store, package_scope, "Handle").type)
	testing.expect(t, handle.kind == .Named && handle.is_nominal && handle.elem == integer)
	testing.expect(t, lookup(&store, package_scope, "Spelling").type == lookup(&store, package_scope, "Handle").type)
	testing.expect(t, types.get(&type_store, lookup(&store, package_scope, "Alias").type).elem == lookup(&store, package_scope, "Handle").type)
	testing.expect(t, types.get(&type_store, lookup(&store, package_scope, "Choice").type).kind == .Union)
	testing.expect(t, types.get(&type_store, lookup(&store, package_scope, "Optional").type).union_form == .Maybe_Pointer)
	callback := types.get(&type_store, lookup(&store, package_scope, "Callback").type)
	testing.expect(t, callback.kind == .Procedure && callback.convention == .C && len(callback.params) == 2 && len(callback.results) == 2)
	table := types.get(&type_store, lookup(&store, package_scope, "Table").type)
	testing.expect(t, table.kind == .Enumerated_Array && table.index == color_id && table.count == 7)
	names_map := types.get(&type_store, lookup(&store, package_scope, "Names").type)
	testing.expect(t, names_map.kind == .Map && names_map.index == integer)
	testing.expect(t, lookup(&store, package_scope, "Bad").type == types.TYPE_POISON)

	expected := []struct {
		kind: Type_Diagnostic_Kind,
		name: string,
	}{{.Undeclared_Type, "Missing"}, {.Duplicate_Field, "a"}, {.Recursive_Value, "Direct"}}
	if testing.expect(t, len(data.checker.diagnostics) == len(expected)) {
		for diagnostic, index in data.checker.diagnostics {
			testing.expect(t, diagnostic.kind == expected[index].kind && diagnostic.name == expected[index].name)
		}
	}
	testing.expect(t, len(resolver.diagnostics) == 3 && resolver.diagnostics[0].kind == .Declaration_Cycle && resolver.diagnostics[0].name == "Loop")
}

@(private = "file")
test_type_resolver :: proc(resolver: ^Resolver, id: Entity_Id, user_data: rawptr) -> (valid: bool, err: Resolve_Error) {
	data := (^Type_Test_Data)(user_data)
	handled: bool
	handled, valid, err = type_declaration(&data.checker, id)
	if handled || err != nil { return }
	entity_get(resolver.scopes, id).type = data.integer
	return true, nil
}

@(private = "file")
test_integer_evaluator :: proc(
	checker: ^Type_Checker,
	scope: Scope_Id,
	file: File_Id,
	expression: syntax.Node_Index,
	user_data: rawptr,
) -> (
	value: i64,
	ok: bool,
	err: Resolve_Error,
) {
	source := checker.files[file]
	span := source.ast.nodes[expression]
	text := string(source.source[span.start:span.end])
	if text == "Count" { return 3, true, nil }
	parsed, parsed_ok := strconv.parse_i64(text)
	return parsed, parsed_ok, nil
}

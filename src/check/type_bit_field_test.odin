package check

import "core:strconv"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(private = "file")
Bit_Field_Test_Data :: struct {
	checker: Type_Checker,
}

@(test)
bit_field_types_pack_fields_and_report_invalid_declarations :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Tagged :: bit_field u64 { pointer: i64 | 57, version: u8 | 7 }
Overflow :: bit_field u8 { a: u8 | 5, b: u8 | 5 }
Wide :: bit_field u8 { a: u8 | 9 }
Arrayed :: bit_field [2]u8 { a: u8 | 3 }
Endian :: bit_field u16 { a: u16be | 4 }
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
	u8_type := types.intern(&type_store, types.Type{kind = .Integer, count = 1})
	u16_type := types.intern(&type_store, types.Type{kind = .Integer, count = 2})
	u16_big := types.intern(&type_store, types.Type{kind = .Integer, count = 2, endianness = .Big})
	u64_type := types.intern(&type_store, types.Type{kind = .Integer, count = 8})
	i64_type := types.intern(&type_store, types.Type{kind = .Integer, count = 8, signed = true})

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
	}{{"u8", u8_type}, {"u16", u16_type}, {"u16be", u16_big}, {"u64", u64_type}, {"i64", i64_type}}
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

	data := Bit_Field_Test_Data{}
	resolver: Resolver
	resolver_init(&resolver, &store, bit_field_test_resolver, &data, context.allocator)
	defer resolver_destroy(&resolver)
	files := []^File{nil, &file}
	type_checker_init(&data.checker, &resolver, &collection, &type_store, files, bit_field_test_integer, nil, context.allocator)
	defer type_checker_destroy(&data.checker)

	names := []string{"Tagged", "Overflow", "Wide", "Arrayed", "Endian"}
	for name in names {
		state, err := resolve_entity(&resolver, scope_lookup_current(&store, package_scope, name))
		testing.expect(t, err == nil)
		testing.expectf(t, (state == .Invalid) == (name != "Tagged" && name != "Arrayed"), "%s: %v", name, state)
	}

	tagged_type := entity_get(&store, scope_lookup_current(&store, package_scope, "Tagged")).type
	tagged := types.get(&type_store, tagged_type)
	if testing.expect(t, tagged.kind == .Bit_Field && tagged.backing == u64_type && len(tagged.fields) == 2) {
		offset, size := types.bit_field_slot(&type_store, tagged_type, 1)
		testing.expect(t, offset == 57 && size == 7 && tagged.fields[1].name == "version")
		layout_size, _, layout_err := types.layout(&type_store, tagged_type)
		testing.expect(t, layout_err == .None && layout_size == 8)
	}

	arrayed_id := entity_get(&store, scope_lookup_current(&store, package_scope, "Arrayed")).type
	arrayed := types.get(&type_store, arrayed_id)
	array_backing := types.intern(&type_store, types.Type{kind = .Array, elem = u8_type, count = 2})
	if testing.expect(t, arrayed.kind == .Bit_Field && arrayed.backing == array_backing && len(arrayed.fields) == 1) {
		offset, size := types.bit_field_slot(&type_store, arrayed_id, 0)
		testing.expect(t, offset == 0 && size == 3 && arrayed.fields[0].name == "a")
		layout_size, _, layout_err := types.layout(&type_store, arrayed_id)
		testing.expect(t, layout_err == .None && layout_size == 2)
	}

	expected := []struct {
		kind: Type_Diagnostic_Kind,
		name: string,
	}{{.Bit_Field_Out_Of_Range, ""}, {.Invalid_Bit_Field_Field, ""}, {.Unsupported_Type_Expression, "Bit_Field_Endian_Field"}}
	if testing.expect(t, len(data.checker.diagnostics) == len(expected)) {
		for diagnostic, index in data.checker.diagnostics {
			testing.expect(t, diagnostic.kind == expected[index].kind && diagnostic.name == expected[index].name)
		}
	}

	address_source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	tagged: bit_field u8 { flag: bool | 1, version: u8 | 7 }
	pointer := &tagged.version
}
`,
	)
	_, _ = check_procedure_source(t, address_source, .Unsupported, "Address_Bit_Field")
}

@(private = "file")
bit_field_test_resolver :: proc(resolver: ^Resolver, id: Entity_Id, user_data: rawptr) -> (valid: bool, err: Resolve_Error) {
	data := (^Bit_Field_Test_Data)(user_data)
	_, valid, err = type_declaration(&data.checker, id)
	return
}

@(private = "file")
bit_field_test_integer :: proc(
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
	value, ok = strconv.parse_i64(string(source.source[span.start:span.end]))
	return value, ok, nil
}

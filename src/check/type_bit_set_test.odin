package check

import "core:strconv"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(private = "file")
Bit_Set_Test_Data :: struct {
	checker: Type_Checker,
	integer: types.Type_Id,
}

@(test)
bit_set_intervals_resolve_bounds_and_report_errors :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Max :: 64
Half :: bit_set[0 ..< 8]
Inclusive :: bit_set[1 ..= 3]
From_Identity :: bit_set[0 ..= Max]
Too_Wide :: bit_set[0 ..= 200]
Backed :: bit_set[0 ..= 15; u16]
Backed_Too_Wide :: bit_set[0 ..= 16; u16]
Backed_Negative :: bit_set[-1 ..= 5; u8]
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
	integer := types.intern(&type_store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	byte_type := types.intern(&type_store, types.Type{kind = .Integer, name = "u8", count = 1})
	short_type := types.intern(&type_store, types.Type{kind = .Integer, name = "u16", count = 2})

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
	}{{"int", integer}, {"u8", byte_type}, {"u16", short_type}}
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

	data := Bit_Set_Test_Data {
		integer = integer,
	}
	resolver: Resolver
	resolver_init(&resolver, &store, bit_set_test_resolver, &data, context.allocator)
	defer resolver_destroy(&resolver)
	files := []^File{nil, &file}
	type_checker_init(&data.checker, &resolver, &collection, &type_store, files, bit_set_test_integer_evaluator, &data, context.allocator)
	defer type_checker_destroy(&data.checker)

	names := []string{"Max", "Half", "Inclusive", "From_Identity", "Too_Wide", "Backed", "Backed_Too_Wide", "Backed_Negative"}
	for name in names {
		state, resolve_err := resolve_entity(&resolver, scope_lookup_current(&store, package_scope, name))
		invalid := name == "Too_Wide" || name == "Backed_Too_Wide" || name == "Backed_Negative"
		testing.expectf(t, (state == .Invalid) == invalid, "%s: %v %v", name, state, resolve_err)
	}
	testing.expect(t, check_nominal_layouts(&data.checker) == nil)

	lookup := proc(store: ^Scope_Store, scope: Scope_Id, name: string) -> types.Type_Id {
		entity := entity_get(store, scope_lookup_current(store, scope, name))
		if entity == nil { return types.TYPE_NONE }
		return entity.type
	}
	if half := lookup(&store, package_scope, "Half"); testing.expect(t, half != types.TYPE_POISON && half != types.TYPE_NONE) {
		descriptor := types.get(&type_store, underlying_type(&type_store, half))
		testing.expectf(t, descriptor.kind == .Bit_Set, "Half: %v", descriptor.kind)
		if descriptor.kind == .Bit_Set {
			testing.expectf(t, descriptor.elem == integer, "Half elem: %v", descriptor.elem)
			testing.expectf(
				t,
				descriptor.lower_bound == 0 && descriptor.upper_bound == 7,
				"Half bounds: %v %v",
				descriptor.lower_bound,
				descriptor.upper_bound,
			)
		}
	}
	if inclusive := lookup(&store, package_scope, "Inclusive"); inclusive != types.TYPE_NONE && inclusive != types.TYPE_POISON {
		descriptor := types.get(&type_store, underlying_type(&type_store, inclusive))
		testing.expectf(
			t,
			descriptor.kind == .Bit_Set && descriptor.lower_bound == 1 && descriptor.upper_bound == 3,
			"Inclusive: %v %v",
			descriptor.lower_bound,
			descriptor.upper_bound,
		)
	}
	if identity := lookup(&store, package_scope, "From_Identity"); identity != types.TYPE_NONE && identity != types.TYPE_POISON {
		descriptor := types.get(&type_store, underlying_type(&type_store, identity))
		testing.expectf(t, descriptor.kind == .Bit_Set && descriptor.upper_bound == 64, "From_Identity: %v", descriptor.upper_bound)
	}
	if wide := lookup(&store, package_scope, "Backed"); wide != types.TYPE_NONE && wide != types.TYPE_POISON {
		descriptor := types.get(&type_store, underlying_type(&type_store, wide))
		testing.expectf(
			t,
			descriptor.kind == .Bit_Set && descriptor.backing == short_type && descriptor.lower_bound == 0 && descriptor.upper_bound == 15,
			"Backed: %v %v %v",
			descriptor.backing,
			descriptor.lower_bound,
			descriptor.upper_bound,
		)
	}

	expected := []Type_Diagnostic_Kind{.Bit_Set_Out_Of_Range, .Bit_Set_Out_Of_Range, .Bit_Set_Out_Of_Range}
	if testing.expectf(t, len(data.checker.diagnostics) == len(expected), "diagnostics: %v", data.checker.diagnostics) {
		for diagnostic, index in data.checker.diagnostics {
			testing.expectf(t, diagnostic.kind == expected[index], "%v: %v", index, diagnostic.kind)
		}
	}
}

@(private = "file")
bit_set_test_resolver :: proc(resolver: ^Resolver, id: Entity_Id, user_data: rawptr) -> (valid: bool, err: Resolve_Error) {
	data := (^Bit_Set_Test_Data)(user_data)
	handled: bool
	handled, valid, err = type_declaration(&data.checker, id)
	if handled || err != nil { return }
	entity_get(resolver.scopes, id).type = data.integer
	return true, nil
}

@(private = "file")
bit_set_test_integer_evaluator :: proc(
	checker: ^Type_Checker,
	scope: Scope_Id,
	file_id: File_Id,
	expression: syntax.Node_Index,
	user_data: rawptr,
) -> (
	value: i64,
	ok: bool,
	err: Resolve_Error,
) {
	source := checker.files[file_id]
	span := source.ast.nodes[expression]
	text := string(source.source[span.start:span.end])
	if id, _ := scope_lookup(checker.resolver.scopes, scope, text); id != 0 {
		entity := entity_get(checker.resolver.scopes, id)
		if entity.kind == .Constant { return 64, true, nil }
	}
	parsed, parsed_ok := strconv.parse_i64(text)
	return parsed, parsed_ok, nil
}

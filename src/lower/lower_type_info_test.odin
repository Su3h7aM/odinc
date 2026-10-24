package lower

import "core:mem/virtual"
import "core:slice"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
type_info_struct_enum_and_procedure_entries_reference_their_members :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	pointer := types.intern(&store, types.Type{kind = .Raw_Pointer, count = 8})
	text := types.intern(&store, types.Type{kind = .String})
	pointers := types.intern(&store, types.Type{kind = .Slice, elem = pointer})
	texts := types.intern(&store, types.Type{kind = .Slice, elem = text})
	integers := types.intern(&store, types.Type{kind = .Slice, elem = integer})
	byte := types.intern(&store, types.Type{kind = .Integer, count = 1})
	payload :: proc(store: ^types.Store, name: string, fields: []types.Type_Field) -> types.Type_Id {
		structure := types.intern(store, types.Type{kind = .Struct, name = name, fields = fields})
		return types.intern(store, types.Type{kind = .Named, name = name, elem = structure})
	}
	integer_variant := payload(&store, "Type_Info_Integer", {{name = "signed", type = boolean}})
	struct_variant := payload(
		&store,
		"Type_Info_Struct",
		{
			{name = "types", type = pointer},
			{name = "names", type = pointer},
			{name = "offsets", type = pointer},
			{name = "usings", type = pointer},
			{name = "tags", type = pointer},
			{name = "field_count", type = integer},
			{name = "flags", type = boolean},
		},
	)
	enum_variant := payload(&store, "Type_Info_Enum", {{name = "base", type = pointer}, {name = "names", type = texts}, {name = "values", type = integers}})
	procedure_variant := payload(
		&store,
		"Type_Info_Procedure",
		{{name = "params", type = pointer}, {name = "results", type = pointer}, {name = "variadic", type = boolean}, {name = "convention", type = boolean}},
	)
	string_variant := payload(&store, "Type_Info_String", {{name = "is_cstring", type = boolean}, {name = "encoding", type = byte}})
	parameters := payload(&store, "Type_Info_Parameters", {{name = "types", type = pointers}, {name = "names", type = texts}})
	variants := types.intern(
		&store,
		types.Type{kind = .Union, variants = {integer_variant, struct_variant, enum_variant, procedure_variant, string_variant, parameters}},
	)
	info := types.intern(
		&store,
		types.Type {
			kind = .Struct,
			name = "Type_Info",
			fields = {{name = "size", type = integer}, {name = "align", type = integer}, {name = "id", type = integer}, {name = "variant", type = variants}},
		},
	)
	pair := types.intern(&store, types.Type{kind = .Struct, name = "Pair", fields = {{name = "first", type = integer}, {name = "second", type = integer}}})
	color := types.intern(&store, types.Type{kind = .Enum, name = "Color", backing = integer, count = 2, lower_bound = 0, upper_bound = 1})
	procedure := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {integer}, results = {integer}})
	string := types.intern(&store, types.Type{kind = .String})
	cstring := types.intern(&store, types.Type{kind = .CString})
	string16 := types.intern(&store, types.Type{kind = .String16})
	cstring16 := types.intern(&store, types.Type{kind = .CString16})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := []check.Expression_Info{{state = .Checked}}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {})
	program.runtime.type_info = fixture_clone(
		[]check.Type_Info_Entry {
			{type = integer, runtime_id = 1, slot = 1, size = 8, alignment = 8},
			{type = pair, runtime_id = 2, slot = 2, size = 16, alignment = 8},
			{type = color, runtime_id = 3, slot = 3, size = 8, alignment = 8},
			{type = procedure, runtime_id = 4, slot = 4, size = 8, alignment = 8},
			{type = string, runtime_id = 5, slot = 5, size = 16, alignment = 8},
			{type = cstring, runtime_id = 6, slot = 6, size = 8, alignment = 8},
			{type = string16, runtime_id = 7, slot = 7, size = 16, alignment = 8},
			{type = cstring16, runtime_id = 8, slot = 8, size = 8, alignment = 8},
		},
		allocator,
	)
	program.runtime.type_info_type = info
	program.runtime.type_info_parameters_type = parameters
	members := fixture_clone([]check.Enum_Member{{name = "Red", value = 0}, {name = "Green", value = 1}}, allocator)
	program.runtime.enum_members = fixture_clone([]check.Enum_Type_Members{{type = color, members = members}}, allocator)
	table_pointer := types.intern(&store, types.Type{kind = .Pointer, elem = info})
	table_slice := types.intern(&store, types.Type{kind = .Slice, elem = table_pointer})
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			program.symbol_table[1],
			{kind = .Global, name = "runtime.type_table", type = table_slice},
			{kind = .Global, name = "__odinc_internal_type_info_entry_1", type = integer},
		},
		allocator,
	)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	defer ir.module_destroy(&module)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(errors), 0)
	if !testing.expect(t, len(module.globals) >= 5) { return }
	// Each entry refers to its members: struct types, names, offsets, usings and tags; enum base, names and values; procedure params and results.
	descriptor_first := 3
	testing.expect_value(t, len(module.globals[descriptor_first + 1].relocs), 5)
	testing.expect_value(t, len(module.globals[descriptor_first + 2].relocs), 3)
	testing.expect_value(t, len(module.globals[descriptor_first + 3].relocs), 2)
	table_global := -1
	backing_global := -1
	for global, index in module.globals {
		if !testing.expect(t, len(global.name) > 0, "every generated metadata global has a link identity") { return }
		for earlier in module.globals[:index] {
			if !testing.expect(t, earlier.name != global.name, "generated metadata global names are unique") { return }
		}
		if global.name == "__odinc_internal_type_info_table_0" { table_global = index }
		if global.name == "runtime.type_table" { backing_global = int(global.relocs[0].target.index) }
	}
	if !testing.expect(t, table_global >= 0 && backing_global == table_global) { return }
	table := module.globals[table_global]
	if !testing.expect_value(t, len(table.relocs), 9) { return }
	testing.expect_value(t, table.relocs[0].offset, u32(0))
	invalid := module.globals[table.relocs[0].target.index]
	testing.expect_value(t, len(invalid.bytes), len(module.globals[descriptor_first].bytes))
	for byte in invalid.bytes { testing.expect_value(t, byte, u8(0)) }
	for relocation, index in table.relocs[1:] {
		testing.expect_value(t, relocation.target, ir.Symbol_Ref{space = .Global, index = u32(descriptor_first + index)})
	}
	string_payload := types.resolve_named(&store, string_variant)
	string_union_offset, _ := types.field_offset(&store, info, 3)
	string_flag_offset, _ := types.field_offset(&store, string_payload, 0)
	string_encoding_offset, _ := types.field_offset(&store, string_payload, 1)
	for index in 0 ..< 4 {
		image := module.globals[descriptor_first + 4 + index].bytes
		testing.expect_value(t, image[string_union_offset + string_flag_offset], u8(index == 1 || index == 3))
		testing.expect_value(t, image[string_union_offset + string_encoding_offset], u8(index >= 2))
	}
}

@(test)
identical_type_info_images_share_one_global :: proc(t: ^testing.T) {
	module: ir.Module
	if !testing.expect_value(t, ir.module_init(&module), nil) { return }
	defer ir.module_destroy(&module)
	writer: Type_Info_Writer
	init_type_info_writer(&writer, &module)
	bytes := []byte{1, 2, 3, 0, 0, 0, 0, 0}
	first, first_error := add_image(&writer, Type_Info_Image{bytes = slice.clone(bytes, writer.allocator) or_else panic("fixture allocation failed")}, 8)
	if !testing.expect_value(t, first_error, nil) { return }
	second, second_error := add_image(&writer, Type_Info_Image{bytes = slice.clone(bytes, writer.allocator) or_else panic("fixture allocation failed")}, 8)
	if !testing.expect_value(t, second_error, nil) { return }
	other_alignment, alignment_error := add_image(
		&writer,
		Type_Info_Image{bytes = slice.clone(bytes, writer.allocator) or_else panic("fixture allocation failed")},
		4,
	)
	if !testing.expect_value(t, alignment_error, nil) { return }
	reloc_image := Type_Info_Image {
		bytes  = slice.clone(bytes, writer.allocator) or_else panic("fixture allocation failed"),
		relocs = make([dynamic]ir.Data_Reloc, writer.allocator) or_else panic("fixture allocation failed"),
	}
	if _, append_error := append(&reloc_image.relocs, ir.Data_Reloc{offset = 0, target = {.Global, 7}}); !testing.expect_value(t, append_error, nil) { return }
	relocated, relocated_error := add_image(&writer, reloc_image, 8)
	if !testing.expect_value(t, relocated_error, nil) { return }
	// Identical bytes, alignment and relocations share one global; equal bytes alone do not.
	testing.expect_value(t, second, first)
	testing.expect(t, other_alignment != first, "a different alignment is a different image")
	testing.expect(t, relocated != first, "a different relocation list is a different image")
	testing.expect_value(t, len(module.globals), 3)
}

@(test)
generated_type_info_names_avoid_function_and_external_symbols :: proc(t: ^testing.T) {
	module: ir.Module
	if !testing.expect_value(t, ir.module_init(&module), nil) { return }
	defer ir.module_destroy(&module)
	function_name := "__odinc_internal_type_info_entry_2"
	external_name := "__odinc_internal_type_info_entry_3"
	function, function_error := ir.function_make(context.allocator, 0, function_name, 0)
	if !testing.expect_value(t, function_error, nil) { return }
	if _, append_error := append(&module.functions, function); !testing.expect_value(t, append_error, nil) { return }
	if _, append_error := append(&module.externs, ir.Extern{name = external_name}); !testing.expect_value(t, append_error, nil) { return }
	writer: Type_Info_Writer
	init_type_info_writer(&writer, &module)
	function_replacement := generated_global_name(&writer, "entry", 2)
	external_replacement := generated_global_name(&writer, "entry", 3)
	testing.expect(t, function_replacement != function_name)
	testing.expect(t, external_replacement != external_name)
}

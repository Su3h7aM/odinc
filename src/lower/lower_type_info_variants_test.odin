package lower

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
Rtti_Ids :: struct {
	boolean, integer, u8, u64, f32, pointer, texts, pointers, integers:  types.Type_Id,
	info, union_payload, matrix_payload, simd_payload, bitfield_payload: types.Type_Id,
	matrix_struct, simd_struct, bitfield_struct:                         types.Type_Id,
}

@(private)
// Descriptor slices are borrowed by the store, so every slice literal is cloned into the test arena: the helper's own frame is gone before lowering runs.
scaffold_type_info_runtime :: proc(store: ^types.Store, allocator: mem.Allocator) -> Rtti_Ids {
	boolean := types.intern(store, types.Type{kind = .Bool})
	integer := types.intern(store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	u8 := types.sized_integer(store, 1, false)
	u64 := types.sized_integer(store, 8, false)
	f32 := types.intern(store, types.Type{kind = .Float, count = 4})
	pointer := types.intern(store, types.Type{kind = .Raw_Pointer})
	text := types.intern(store, types.Type{kind = .String})
	texts := types.intern(store, types.Type{kind = .Slice, elem = text})
	pointers := types.intern(store, types.Type{kind = .Slice, elem = pointer})
	integers := types.intern(store, types.Type{kind = .Slice, elem = integer})
	named :: proc(store: ^types.Store, allocator: mem.Allocator, name: string, fields: []types.Type_Field) -> (named_id, structure_id: types.Type_Id) {
		structure_id = types.intern(store, types.Type{kind = .Struct, name = name, fields = fixture_clone(fields, allocator)})
		named_id = types.intern(store, types.Type{kind = .Named, name = name, elem = structure_id})
		return
	}
	integer_payload, _ := named(store, allocator, "Type_Info_Integer", {{name = "signed", type = boolean}})
	boolean_payload, _ := named(store, allocator, "Type_Info_Boolean", {})
	float_payload, _ := named(store, allocator, "Type_Info_Float", {})
	union_payload, _ := named(
		store,
		allocator,
		"Type_Info_Union",
		{
			{name = "variants", type = pointers},
			{name = "tag_offset", type = integer},
			{name = "tag_type", type = pointer},
			{name = "custom_align", type = boolean},
			{name = "no_nil", type = boolean},
			{name = "shared_nil", type = boolean},
		},
	)
	matrix_payload, matrix_struct := named(
		store,
		allocator,
		"Type_Info_Matrix",
		{
			{name = "elem", type = pointer},
			{name = "elem_size", type = integer},
			{name = "elem_stride", type = integer},
			{name = "row_count", type = integer},
			{name = "column_count", type = integer},
			{name = "layout", type = u8},
		},
	)
	simd_payload, simd_struct := named(
		store,
		allocator,
		"Type_Info_Simd_Vector",
		{{name = "elem", type = pointer}, {name = "elem_size", type = integer}, {name = "count", type = integer}},
	)
	bitfield_payload, bitfield_struct := named(
		store,
		allocator,
		"Type_Info_Bit_Field",
		{
			{name = "backing_type", type = pointer},
			{name = "names", type = texts},
			{name = "types", type = pointers},
			{name = "bit_sizes", type = integers},
			{name = "bit_offsets", type = integers},
			{name = "tags", type = texts},
			{name = "field_count", type = integer},
		},
	)
	variants := types.intern(
		store,
		types.Type {
			kind = .Union,
			variants = fixture_clone(
				[]types.Type_Id{integer_payload, boolean_payload, float_payload, union_payload, matrix_payload, simd_payload, bitfield_payload},
				allocator,
			),
		},
	)
	info := types.intern(
		store,
		types.Type {
			kind = .Struct,
			name = "Type_Info",
			fields = fixture_clone(
				[]types.Type_Field {
					{name = "size", type = integer},
					{name = "align", type = integer},
					{name = "id", type = integer},
					{name = "variant", type = variants},
				},
				allocator,
			),
		},
	)
	return {
		boolean,
		integer,
		u8,
		u64,
		f32,
		pointer,
		texts,
		pointers,
		integers,
		info,
		union_payload,
		matrix_payload,
		simd_payload,
		bitfield_payload,
		matrix_struct,
		simd_struct,
		bitfield_struct,
	}
}

@(private)
type_info_entry_for_test :: proc(store: ^types.Store, type: types.Type_Id, slot: u32) -> check.Type_Info_Entry {
	size, alignment, _ := types.layout(store, type)
	return {type = type, runtime_id = u64(slot), slot = slot, size = size, alignment = alignment}
}

@(private)
lower_entries_for_test :: proc(
	t: ^testing.T,
	allocator: mem.Allocator,
	ast: ^syntax.Ast,
	store: ^types.Store,
	info: types.Type_Id,
	entries: []check.Type_Info_Entry,
	module: ^ir.Module,
) -> bool {
	body := syntax.ast_add_node(ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{})
	signature := types.intern(store, types.Type{kind = .Procedure, convention = .Contextless})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}}, allocator)
	facts := []check.Expression_Info{{state = .Checked}}
	program := expression_fixture(ast, store, allocator, body, signature, entities, facts, {})
	program.runtime.type_info = fixture_clone(entries, allocator)
	program.runtime.type_info_type = info
	table_pointer := types.intern(store, types.Type{kind = .Pointer, elem = info})
	table_slice := types.intern(store, types.Type{kind = .Slice, elem = table_pointer})
	program.symbol_table = fixture_clone(
		[]check.Symbol{{}, program.symbol_table[1], {kind = .Global, name = "runtime.type_table", type = table_slice}},
		allocator,
	)
	requirements := check.runtime_requirements(&program)
	testing.expect_value(t, requirements.type_info_type, info)
	testing.expect(t, check.type_store(&program) == store, "lowering must see the fixture store")
	testing.expect_value(t, len(requirements.type_info), len(entries))
	struct_id := types.resolve_named(store, info)
	testing.expect_value(t, struct_id, info)
	union_by_index := types.get(store, info).fields[3].type
	union_by_search: types.Type_Id
	for field in types.get(store, struct_id).fields {
		if field.name == "variant" { union_by_search = field.type }
	}
	testing.expect_value(t, union_by_search, union_by_index)
	union_layout, union_error := types.union_layout(store, union_by_search)
	testing.expect_value(t, union_error, types.Layout_Error.None)
	testing.expect(t, union_layout.tag_size > 0, "scaffold union must have a tag")
	variant_field, variant_found := "", false
	for field in types.get(store, info).fields {
		if field.name == "variant" { variant_field, variant_found = field.name, true }
	}
	testing.expect(t, variant_found, "scaffold info must declare a variant field")
	union_id := types.get(store, info).fields[3].type
	_ = variant_field
	wants := []string {
		"Type_Info_Integer",
		"Type_Info_Boolean",
		"Type_Info_Float",
		"Type_Info_Union",
		"Type_Info_Matrix",
		"Type_Info_Simd_Vector",
		"Type_Info_Bit_Field",
	}
	for want in wants {
		matched := false
		for variant in types.get(store, union_id).variants {
			if strings.has_suffix(types.get(store, variant).name, want) { matched = true }
		}
		testing.expectf(t, matched, "scaffold union must declare %s", want)
	}
	errors, err := lower_program(&program, module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) {
		ir.module_destroy(module)
		return false
	}
	return true
}

@(private)
table_entry_global :: proc(t: ^testing.T, module: ^ir.Module, slot: u32) -> int {
	for global in module.globals {
		if global.name != "__odinc_internal_type_info_table_0" { continue }
		if !testing.expect(t, len(global.relocs) > int(slot)) { return -1 }
		return int(global.relocs[slot].target.index)
	}
	testing.expect(t, false, "type info table global missing")
	return -1
}

@(private)
read_u64_le :: proc(bytes: []byte, offset: i64) -> u64 {
	value := u64(0)
	for index in 0 ..< 8 { value |= u64(bytes[offset + i64(index)]) << uint(8 * index) }
	return value
}

@(private)
field_value_offset :: proc(t: ^testing.T, store: ^types.Store, structure: types.Type_Id, position: int) -> i64 {
	offset, offset_error := types.field_offset(store, structure, position)
	testing.expect_value(t, offset_error, types.Layout_Error.None)
	return offset
}

// A payload scalar inside a Type_Info image: the variant block starts where the info's variant field sits.
@(private)
payload_value :: proc(t: ^testing.T, store: ^types.Store, info: types.Type_Id, structure: types.Type_Id, bytes: []byte, position: int) -> u64 {
	base := field_value_offset(t, store, info, 3)
	return read_u64_le(bytes, base + field_value_offset(t, store, structure, position))
}

@(test)
union_tag_type_reuses_builtin_integer_entry :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	ids := scaffold_type_info_runtime(&store, allocator)
	test_union := types.intern(&store, types.Type{kind = .Union, variants = {ids.integer, ids.boolean}})
	entries := []check.Type_Info_Entry {
		type_info_entry_for_test(&store, ids.integer, 1),
		type_info_entry_for_test(&store, ids.boolean, 2),
		type_info_entry_for_test(&store, ids.u64, 3),
		type_info_entry_for_test(&store, test_union, 4),
	}
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	module: ir.Module
	if !lower_entries_for_test(t, allocator, &ast, &store, ids.info, entries, &module) { return }
	defer ir.module_destroy(&module)
	union_global := table_entry_global(t, &module, 4)
	u64_global := table_entry_global(t, &module, 3)
	if union_global < 0 || u64_global < 0 { return }
	image := module.globals[union_global]
	if !testing.expect_value(t, len(image.relocs), 2) { return }
	testing.expect_value(t, int(image.relocs[1].target.index), u64_global)
}

@(test)
matrix_type_info_records_rows_columns_and_stride :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	ids := scaffold_type_info_runtime(&store, allocator)
	mat := types.intern(&store, types.Type{kind = .Matrix, elem = ids.f32, count = 2, upper_bound = 3})
	entries := []check.Type_Info_Entry{type_info_entry_for_test(&store, ids.f32, 1), type_info_entry_for_test(&store, mat, 2)}
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	module: ir.Module
	if !lower_entries_for_test(t, allocator, &ast, &store, ids.info, entries, &module) { return }
	defer ir.module_destroy(&module)
	mat_global := table_entry_global(t, &module, 2)
	elem_global := table_entry_global(t, &module, 1)
	if mat_global < 0 || elem_global < 0 { return }
	image := module.globals[mat_global]
	if !testing.expect_value(t, len(image.relocs), 1) { return }
	testing.expect_value(t, int(image.relocs[0].target.index), elem_global)
	testing.expect_value(t, payload_value(t, &store, ids.info, ids.matrix_struct, image.bytes, 1), u64(4))
	testing.expect_value(t, payload_value(t, &store, ids.info, ids.matrix_struct, image.bytes, 2), u64(2))
	testing.expect_value(t, payload_value(t, &store, ids.info, ids.matrix_struct, image.bytes, 3), u64(2))
	testing.expect_value(t, payload_value(t, &store, ids.info, ids.matrix_struct, image.bytes, 4), u64(3))
	base := field_value_offset(t, &store, ids.info, 3)
	testing.expect_value(t, image.bytes[base + field_value_offset(t, &store, ids.matrix_struct, 5)], u8(0))
}

@(test)
simd_vector_type_info_records_element_and_count :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	ids := scaffold_type_info_runtime(&store, allocator)
	vec := types.intern(&store, types.Type{kind = .Simd_Vector, elem = ids.f32, count = 4})
	entries := []check.Type_Info_Entry{type_info_entry_for_test(&store, ids.f32, 1), type_info_entry_for_test(&store, vec, 2)}
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	module: ir.Module
	if !lower_entries_for_test(t, allocator, &ast, &store, ids.info, entries, &module) { return }
	defer ir.module_destroy(&module)
	vec_global := table_entry_global(t, &module, 2)
	elem_global := table_entry_global(t, &module, 1)
	if vec_global < 0 || elem_global < 0 { return }
	image := module.globals[vec_global]
	if !testing.expect_value(t, len(image.relocs), 1) { return }
	testing.expect_value(t, int(image.relocs[0].target.index), elem_global)
	testing.expect_value(t, payload_value(t, &store, ids.info, ids.simd_struct, image.bytes, 1), u64(4))
	testing.expect_value(t, payload_value(t, &store, ids.info, ids.simd_struct, image.bytes, 2), u64(4))
}

@(test)
bit_field_type_info_records_prefix_sum_offsets :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	ids := scaffold_type_info_runtime(&store, allocator)
	backing := types.sized_integer(&store, 4, false)
	fields := []types.Type_Field{{name = "x", type = ids.u8}, {name = "y", type = ids.boolean}}
	bitfield := types.intern(&store, types.Type{kind = .Bit_Field, backing = backing, fields = fields, bit_sizes = {8, 1}})
	entries := []check.Type_Info_Entry {
		type_info_entry_for_test(&store, backing, 1),
		type_info_entry_for_test(&store, ids.u8, 2),
		type_info_entry_for_test(&store, ids.boolean, 3),
		type_info_entry_for_test(&store, bitfield, 4),
	}
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	module: ir.Module
	if !lower_entries_for_test(t, allocator, &ast, &store, ids.info, entries, &module) { return }
	defer ir.module_destroy(&module)
	bitfield_global := table_entry_global(t, &module, 4)
	backing_global := table_entry_global(t, &module, 1)
	if bitfield_global < 0 || backing_global < 0 { return }
	image := module.globals[bitfield_global]
	if !testing.expect_value(t, len(image.relocs), 6) { return }
	testing.expect_value(t, int(image.relocs[0].target.index), backing_global)
	testing.expect_value(t, payload_value(t, &store, ids.info, ids.bitfield_struct, image.bytes, 6), u64(2))
	sizes_global := int(image.relocs[3].target.index)
	offsets_global := int(image.relocs[4].target.index)
	sizes := module.globals[sizes_global].bytes
	offsets := module.globals[offsets_global].bytes
	if !testing.expect_value(t, len(sizes), 16) { return }
	if !testing.expect_value(t, len(offsets), 16) { return }
	testing.expect_value(t, read_u64_le(sizes, 0), u64(8))
	testing.expect_value(t, read_u64_le(sizes, 8), u64(1))
	testing.expect_value(t, read_u64_le(offsets, 0), u64(0))
	testing.expect_value(t, read_u64_le(offsets, 8), u64(8))
}

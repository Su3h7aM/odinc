package types

import "core:testing"

@(test)
descriptor_address_survives_store_growth :: proc(t: ^testing.T) {
	store := init()
	defer destroy(&store)
	first := intern(&store, Type{kind = .Integer, name = "stable", count = 8, signed = true})
	pointer := get(&store, first)
	for count in 1 ..< 1000 {
		_ = intern(&store, Type{kind = .Array, elem = TYPE_POISON, count = i64(count)})
	}
	testing.expect(t, get(&store, first) == pointer, "a descriptor keeps its address as the store grows")
	testing.expect_value(t, pointer.name, "stable")
}

Layout_Case :: struct {
	type:            Type_Id,
	size, alignment: i64,
}

Untyped_Default_Case :: struct {
	source: Type_Id,
	kind:   Kind,
	count:  i64,
	signed: bool,
}

@(test)
layout_matches_target :: proc(t: ^testing.T) {
	Node :: struct {
		next: ^Node,
	}
	store := init()
	defer destroy(&store)
	testing.expect(t, TYPE_NONE == Type_Id(0), "zero type id is inert")
	testing.expect(
		t,
		TYPE_UNTYPED_BOOL == Type_Id(2) &&
		TYPE_UNTYPED_INTEGER == Type_Id(3) &&
		TYPE_UNTYPED_RUNE == Type_Id(4) &&
		TYPE_UNTYPED_FLOAT == Type_Id(5) &&
		TYPE_UNTYPED_COMPLEX == Type_Id(6) &&
		TYPE_UNTYPED_QUATERNION == Type_Id(7) &&
		TYPE_UNTYPED_STRING == Type_Id(8) &&
		TYPE_UNTYPED_NIL == Type_Id(9),
		"untyped type ids are stable",
	)
	default_cases := []Untyped_Default_Case {
		{TYPE_UNTYPED_BOOL, .Bool, 0, false},
		{TYPE_UNTYPED_INTEGER, .Integer, DEFAULT_LAYOUT.int_size, true},
		{TYPE_UNTYPED_RUNE, .Rune, 4, true},
		{TYPE_UNTYPED_FLOAT, .Float, 8, false},
		{TYPE_UNTYPED_COMPLEX, .Complex, 16, false},
		{TYPE_UNTYPED_QUATERNION, .Quaternion, 32, false},
		{TYPE_UNTYPED_STRING, .String, 0, false},
	}
	for test_case in default_cases {
		default_id := default_type_of_untyped(&store, test_case.source)
		default_descriptor := get(&store, default_id)
		testing.expect(
			t,
			default_descriptor.kind == test_case.kind &&
			default_descriptor.count == test_case.count &&
			default_descriptor.signed == test_case.signed &&
			!is_untyped(&store, default_id),
			"untyped value has its default typed type",
		)
	}
	testing.expect(
		t,
		is_untyped(&store, TYPE_UNTYPED_NIL) && default_type_of_untyped(&store, TYPE_UNTYPED_NIL) == TYPE_UNTYPED_NIL,
		"untyped nil stays untyped",
	)
	untyped_size, _, untyped_layout_err := layout(&store, TYPE_UNTYPED_FLOAT)
	testing.expect(t, untyped_layout_err == .Invalid_Type && untyped_size == 0, "untyped type has no layout")
	id_i8 := intern(&store, Type{kind = .Integer, count = 1, signed = true})
	id_u8 := intern(&store, Type{kind = .Integer, count = 1})
	id_u16 := intern(&store, Type{kind = .Integer, count = 2})
	id_u32 := intern(&store, Type{kind = .Integer, count = 4})
	id_u64 := intern(&store, Type{kind = .Integer, count = 8})
	id_int := intern(&store, Type{kind = .Integer, count = DEFAULT_LAYOUT.int_size, signed = true})
	id_f64 := intern(&store, Type{kind = .Float, count = 8})
	id_rune := intern(&store, Type{kind = .Rune, count = 4})
	id_complex := intern(&store, Type{kind = .Complex, count = 8})
	id_quaternion := intern(&store, Type{kind = .Quaternion, count = 16})
	id_pointer := intern(&store, Type{kind = .Pointer, elem = id_u8})
	id_multi_pointer := intern(&store, Type{kind = .Multi_Pointer, elem = id_u8})
	id_slice := intern(&store, Type{kind = .Slice, elem = id_u8})
	id_string := intern(&store, Type{kind = .String})
	id_cstring := intern(&store, Type{kind = .CString})
	id_any := intern(&store, Type{kind = .Any})
	id_typeid := intern(&store, Type{kind = .Type_Id})
	id_array := intern(&store, Type{kind = .Array, elem = id_u32, count = 3})
	id_enum := intern(&store, Type{kind = .Enum, backing = id_u16})
	id_bit_set := intern(&store, Type{kind = .Bit_Set, backing = TYPE_NONE, lower_bound = 0, upper_bound = 63})
	id_bit_field := intern(&store, Type{kind = .Bit_Field, backing = id_u32})
	fields := []Type_Field{{name = "a", type = id_u8}, {name = "b", type = id_u64}}
	id_struct := intern(&store, Type{kind = .Struct, fields = fields})
	id_packed := intern(&store, Type{kind = .Struct, fields = fields, packed = true})
	id_raw_union := intern(&store, Type{kind = .Struct, fields = fields, raw_union = true})
	id_field_cap := intern(&store, Type{kind = .Struct, fields = fields, min_field_align = 4, max_field_align = 4})
	custom_fields := []Type_Field{{name = "a", type = id_u64}, {name = "b", type = id_u64}, {name = "c", type = id_u64}, {name = "d", type = id_u64}}
	id_custom_align := intern(&store, Type{kind = .Struct, fields = custom_fields, custom_align = 16})
	id_union := intern(&store, Type{kind = .Union, variants = []Type_Id{id_u8, id_u64}})
	id_maybe_pointer := intern(&store, Type{kind = .Union, variants = []Type_Id{id_pointer}, union_form = .Maybe_Pointer})
	id_dynamic_array := intern(&store, Type{kind = .Dynamic_Array, elem = id_u32})
	id_map := intern(&store, Type{kind = .Map, elem = id_u32, index = id_u32})
	id_simd := intern(&store, Type{kind = .Simd_Vector, elem = id_u32, count = 4})
	id_matrix := intern(&store, Type{kind = .Matrix, elem = id_u32, count = 4, upper_bound = 3})
	id_procedure := intern(&store, Type{kind = .Procedure, convention = .C})

	cases := []Layout_Case {
		{id_i8, size_of(i8), align_of(i8)},
		{id_u16, size_of(u16), align_of(u16)},
		{id_u32, size_of(u32), align_of(u32)},
		{id_u64, size_of(u64), align_of(u64)},
		{id_f64, size_of(f64), align_of(f64)},
		{id_rune, size_of(rune), align_of(rune)},
		{id_complex, size_of(complex64), align_of(complex64)},
		{id_quaternion, size_of(quaternion128), align_of(quaternion128)},
		{id_pointer, size_of(^u8), align_of(^u8)},
		{id_multi_pointer, size_of([^]u8), align_of([^]u8)},
		{id_slice, size_of([]u8), align_of([]u8)},
		{id_string, size_of(string), align_of(string)},
		{id_cstring, size_of(cstring), align_of(cstring)},
		{id_any, size_of(any), align_of(any)},
		{id_typeid, size_of(typeid), align_of(typeid)},
		{id_array, size_of([3]u32), align_of([3]u32)},
		{id_enum, size_of(u16), align_of(u16)},
		{id_bit_set, 8, 8},
		{id_bit_field, size_of(u32), align_of(u32)},
		{id_struct, size_of(struct {
					a: u8,
					b: u64,
				}), align_of(struct {
					a: u8,
					b: u64,
				})},
		{id_packed, size_of(struct #packed {
					a: u8,
					b: u64,
				}), align_of(struct #packed {
					a: u8,
					b: u64,
				})},
		{id_raw_union, size_of(struct #raw_union {
					a: u8,
					b: u64,
				}), align_of(struct #raw_union {
					a: u8,
					b: u64,
				})},
		{id_field_cap, size_of(struct #max_field_align(4) #min_field_align(4) {
					a: u8,
					b: u64,
				}), align_of(struct #max_field_align(4) #min_field_align(4) {
					a: u8,
					b: u64,
				})},
		{id_union, 16, 8},
		{id_maybe_pointer, 8, 8},
		{id_dynamic_array, size_of([dynamic]u32), align_of([dynamic]u32)},
		{id_map, 4 * size_of(rawptr), align_of(rawptr)},
		{id_simd, 16, 16},
		{id_matrix, size_of(matrix[4, 3]u32), align_of(matrix[4, 3]u32)},
		{id_procedure, size_of(proc "c" ()), align_of(proc "c" ())},
	}

	for test_case in cases {
		size, alignment, layout_err := layout(&store, test_case.type)
		testing.expect(t, layout_err == .None, "layout succeeds")
		testing.expect(t, size == test_case.size, "type size matches compiler")
		testing.expect(t, alignment == test_case.alignment, "type alignment matches compiler")
	}
	union_info, union_err := union_layout(&store, id_union)
	testing.expect(t, union_err == .None, "union layout succeeds")
	testing.expect(t, union_info.size == 16 && union_info.variant_block_size == 8 && union_info.tag_size == 8, "tagged union descriptor")
	maybe, maybe_err := union_layout(&store, id_maybe_pointer)
	testing.expect(t, maybe_err == .None, "maybe-pointer union layout succeeds")
	testing.expect(t, maybe.size == 8 && maybe.tag_size == 0, "maybe-pointer union omits its tag")
	struct_offset, offset_err := field_offset(&store, id_struct, 1)
	testing.expect(t, offset_err == .None && struct_offset == i64(offset_of(struct {
						a: u8,
						b: u64,
					}, b)), "struct field offset")
	packed_offset, packed_err := field_offset(&store, id_packed, 1)
	testing.expect(t, packed_err == .None && packed_offset == i64(offset_of(struct #packed {
						a: u8,
						b: u64,
					}, b)), "packed field offset")
	field_cap_offset, field_cap_err := field_offset(&store, id_field_cap, 1)
	testing.expect(t, field_cap_err == .None && field_cap_offset == i64(offset_of(struct #max_field_align(4) #min_field_align(4) {
						a: u8,
						b: u64,
					}, b)), "capped field alignment offset")
	custom_size, custom_alignment, custom_err := layout(&store, id_custom_align)
	custom_offset, custom_offset_err := field_offset(&store, id_custom_align, 3)
	testing.expect(t, custom_err == .None && custom_size == 32 && custom_alignment == 16, "custom alignment preserves sequential record size")
	testing.expect(t, custom_offset_err == .None && custom_offset == 24, "custom-aligned record preserves sequential field offsets")
	duplicate := intern(&store, Type{kind = .Integer, count = 4})
	testing.expect(t, duplicate == id_u32, "interning preserves canonical identity")
	node_id := reserve_nominal(&store, .Struct, "Node")
	node_pointer := intern(&store, Type{kind = .Pointer, elem = node_id})
	complete_nominal(&store, node_id, Type{kind = .Struct, name = "Node", fields = []Type_Field{{name = "next", type = node_pointer}}})
	node_size, node_align, node_err := layout(&store, node_id)
	testing.expect(t, node_err == .None && node_size == size_of(Node) && node_align == align_of(Node), "recursive pointer record lays out")
	distinct_id := reserve_nominal(&store, .Named, "Distinct_Int")
	distinct_pointer := intern(&store, Type{kind = .Pointer, elem = distinct_id})
	complete_nominal(&store, distinct_id, Type{kind = .Named, name = "Distinct_Int", elem = id_int})
	distinct_size, distinct_align, distinct_err := layout(&store, distinct_id)
	testing.expect(
		t,
		distinct_err == .None && distinct_size == size_of(int) && distinct_align == align_of(int) && get(&store, distinct_pointer).elem == distinct_id,
		"forward-reserved named type keeps its id and lays out its base",
	)
	incomplete_id := reserve_nominal(&store, .Struct, "Incomplete")
	_, _, incomplete_err := layout(&store, incomplete_id)
	testing.expect(t, incomplete_err == .Incomplete_Type, "incomplete nominal type returns layout error")
	cycle_id := reserve_nominal(&store, .Struct, "Cycle")
	complete_nominal(&store, cycle_id, Type{kind = .Struct, name = "Cycle", fields = []Type_Field{{name = "self", type = cycle_id}}})
	_, _, cycle_err := layout(&store, cycle_id)
	testing.expect(t, cycle_err == .Recursive_Value, "by-value recursive record returns layout error")
	_, _, poison_err := layout(&store, TYPE_POISON)
	testing.expect(t, poison_err == .Poison, "poison type has no layout")
}

@(test)
target_feature_levels_are_cumulative :: proc(t: ^testing.T) {
	previous := x86_level_features(.V1)
	testing.expect(t, card(previous) == 7, "v1 carries its seven architectural features")
	for level in X86_Level {
		current := x86_level_features(level)
		for feature in X86_Feature {
			if feature in previous {
				testing.expect(t, feature in current, "higher levels keep every lower feature")
			}
		}
		testing.expect(t, level == .V1 || card(current) > card(previous), "higher levels add features")
		previous = current
	}
	independent := X86_Features{.Aes, .Pclmul, .Sha, .Adx, .Rdrand, .Rdseed}
	for level in X86_Level {
		features := x86_level_features(level)
		for feature in independent {
			testing.expect(t, feature not_in features, "level sets hold no independent feature")
		}
	}
}

package types

import "core:testing"

Class_Case :: struct {
	name:    string,
	type:    Type_Id,
	classes: []Reg_Class,
}

scalar :: proc(store: ^Store, kind: Kind, bytes: i64) -> Type_Id {
	return intern(store, Type{kind = kind, count = bytes})
}

record :: proc(store: ^Store, template: Type, members: ..Type_Id) -> Type_Id {
	descriptor := template
	descriptor.kind = .Struct
	descriptor.fields = make([]Type_Field, len(members), context.temp_allocator)
	for member, index in members { descriptor.fields[index] = Type_Field{"", member} }
	return intern(store, descriptor)
}

array_of :: proc(store: ^Store, elem: Type_Id, count: i64) -> Type_Id {
	return intern(store, Type{kind = .Array, elem = elem, count = count})
}

union_of :: proc(store: ^Store, template: Type, members: ..Type_Id) -> Type_Id {
	descriptor := template
	descriptor.kind = .Union
	descriptor.variants = make([]Type_Id, len(members), context.temp_allocator)
	copy(descriptor.variants, members)
	return intern(store, descriptor)
}

// Expected vectors come from the fork's `odin build -build-mode:llvm-ir` output for
// `proc "c"` parameters: byval/sret is MEMORY, `i64`/`ptr` INTEGER, `double`/`float`/`<N x ...>` SSE,
// `{ double, i64 }` SSE then INTEGER. The 128-bit integer and the 32-byte #align case follow
// `classify` in llvm_abi.cpp (LLVM shows `i128` and byval align 32).
@(test)
classify_matches_compiler :: proc(t: ^testing.T) {
	store := init()
	defer destroy(&store)
	defer free_all(context.temp_allocator)

	u8 := scalar(&store, .Integer, 1)
	i32 := scalar(&store, .Integer, 4)
	i64 := scalar(&store, .Integer, 8)
	i128 := scalar(&store, .Integer, 16)
	f16 := scalar(&store, .Float, 2)
	f32 := scalar(&store, .Float, 4)
	f64 := scalar(&store, .Float, 8)
	u16 := scalar(&store, .Integer, 2)
	pointer := intern(&store, Type{kind = .Pointer, elem = u8})
	multi_pointer := intern(&store, Type{kind = .Multi_Pointer, elem = f32})
	v2 := record(&store, {}, f32, f32)
	f32_pair := array_of(&store, f32, 2)
	f32_quad := array_of(&store, f32, 4)
	packed := Type {
		packed = true,
	}
	raw_union := Type {
		raw_union = true,
	}

	I :: Reg_Class.Integer
	S :: Reg_Class.SSE
	U :: Reg_Class.SSE_Up
	M :: Reg_Class.Memory

	cases := []Class_Case {
		{"u8", u8, {I}},
		{"f32", f32, {S}},
		{"f64", f64, {S}},
		{"rawptr", intern(&store, Type{kind = .Raw_Pointer}), {I}},
		{"u128", i128, {I, I}},
		{"{i32,i32}", record(&store, {}, i32, i32), {I}},
		{"{f32,f32}", v2, {S}},
		{"{f32,f32,f32}", record(&store, {}, f32, f32, f32), {S, S}},
		{"{f64,f64}", record(&store, {}, f64, f64), {S, S}},
		{"{f64,i64}", record(&store, {}, f64, i64), {S, I}},
		{"{i64,f64}", record(&store, {}, i64, f64), {I, S}},
		{"{f32,i32}", record(&store, {}, f32, i32), {I}},
		{"{u8,u16,u8}", record(&store, {}, u8, u16, u8), {I}},
		{"[3]f32", array_of(&store, f32, 3), {S, S}},
		{"[4]f32", f32_quad, {S, S}},
		{"string", intern(&store, Type{kind = .String}), {I, I}},
		{"[]int", intern(&store, Type{kind = .Slice, elem = i64}), {I, I}},
		{"any", intern(&store, Type{kind = .Any}), {I, I}},
		{"[dynamic]int", intern(&store, Type{kind = .Dynamic_Array, elem = i64}), {M, M, M, M, M}},
		{"map", intern(&store, Type{kind = .Map, elem = i64, index = i64}), {M, M, M, M}},
		{"{i64,i64,i64}", record(&store, {}, i64, i64, i64), {M, M, M}},
		{"{f64,f64,f64}", record(&store, {}, f64, f64, f64), {M, M, M}},
		{"raw_union{f32,u32}", record(&store, raw_union, f32, i32), {I}},
		{"raw_union{f32,f32}", record(&store, raw_union, f32, f32), {S}},
		{"raw_union{f32,f64}", record(&store, raw_union, f32, f64), {S}},
		{"union{f32,u32}", union_of(&store, {}, f32, i32), {I}},
		{"union{^int} maybe", union_of(&store, Type{union_form = .Maybe_Pointer}, pointer), {I}},
		{"union{[4]i64,i32}", union_of(&store, {}, array_of(&store, i64, 4), i32), {M, M, M, M, M}},
		{"#packed{u8,f32}", record(&store, packed, u8, f32), {M}},
		{"#packed{f32,f32}", record(&store, packed, f32, f32), {S}},
		{"#align(32){f32}", record(&store, Type{custom_align = 32}, f32), {M, M, M, M}},
		{"#align(16){f32}", record(&store, Type{custom_align = 16}, f32), {S}},
		{"complex64", scalar(&store, .Complex, 8), {S}},
		{"complex128", scalar(&store, .Complex, 16), {S, S}},
		{"quaternion128", scalar(&store, .Quaternion, 16), {S, S}},
		{"quaternion256", scalar(&store, .Quaternion, 32), {M, M, M, M}},
		{"#simd[4]f32", intern(&store, Type{kind = .Simd_Vector, elem = f32, count = 4}), {S, U}},
		{"#simd[2]f32", intern(&store, Type{kind = .Simd_Vector, elem = f32, count = 2}), {S}},
		{"matrix[2,2]f32", intern(&store, Type{kind = .Matrix, elem = f32, count = 2, upper_bound = 2}), {S, S}},
		{"matrix[3,3]f32", intern(&store, Type{kind = .Matrix, elem = f32, count = 3, upper_bound = 3}), {M, M, M, M, M}},
		{"enum u8", intern(&store, Type{kind = .Enum, backing = u8}), {I}},
		{"bit_set u32", intern(&store, Type{kind = .Bit_Set, backing = i32}), {I}},
		{"f16", f16, {S}},
		{"{f16,f16,f16}", record(&store, {}, f16, f16, f16), {S}},
		{"{f32,f16}", record(&store, {}, f32, f16), {S}},
		{"{}", record(&store, {}), {}},
		{"#soa[2]V2", record(&store, Type{soa = .Fixed}, f32_pair, f32_pair), {S, S}},
		{"#soa[4]V2", record(&store, Type{soa = .Fixed}, array_of(&store, f32, 4), array_of(&store, f32, 4)), {M, M, M, M}},
		{"#soa[]V2", record(&store, Type{soa = .Slice}, multi_pointer, multi_pointer, i64), {M, M, M}},
		{"{u8,f32}", record(&store, {}, u8, f32), {I}},
		{"{f32,f32,i64}", record(&store, {}, f32, f32, i64), {S, I}},
		{"{i128}", record(&store, {}, i128), {I, I}},
		{"cstring", intern(&store, Type{kind = .CString}), {I}},
		{"[9]u8 in struct", record(&store, {}, array_of(&store, u8, 9)), {I, I}},
		{"#min_field_align(16){u8,f32}", record(&store, Type{min_field_align = 16}, u8, f32), {M, M, M, M}},
		{"[2]V2", array_of(&store, v2, 2), {S, S}},
		{"{f32,{f32,i32}}", record(&store, {}, f32, record(&store, {}, f32, i32)), {S, I}},
	}

	for test_case in cases {
		result, err := classify(&store, test_case.type)
		testing.expect(t, err == .None, test_case.name)
		testing.expectf(t, int(result.count) == len(test_case.classes), "%s: %d eightbytes, want %d", test_case.name, result.count, len(test_case.classes))
		for expected, index in test_case.classes {
			if index < int(result.count) {
				testing.expectf(
					t,
					result.classes[index] == expected,
					"%s: eightbyte %d is %v, want %v",
					test_case.name,
					index,
					result.classes[index],
					expected,
				)
			}
		}
	}
}

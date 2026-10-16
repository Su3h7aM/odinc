package types

import "core:fmt"
import "core:strings"
import "core:testing"

Plan_Case :: struct {
	name:       string,
	convention: Calling_Convention,
	params:     []Type_Id,
	by_pointer: []bool,
	results:    []Type_Id,
	expected:   string,
}

procedure_type :: proc(store: ^Store, convention: Calling_Convention, params, results: []Type_Id, variadic := false) -> Type_Id {
	return intern(store, Type{kind = .Procedure, convention = convention, params = params, results = results, variadic = variadic})
}

natural_bytes :: proc(piece: Abi_Piece) -> u32 {
	switch piece {
	case .I8:
		return 1
	case .I16, .F16:
		return 2
	case .I32, .F32:
		return 4
	case .V128:
		return 16
	case .I64, .F64, .Ptr:
		return 8
	}
	return 0
}

// describe renders a plan as "params -> results": a piece is its type, then z/s
// for zero/sign extension, "/n" when only n bytes are significant, "@n" for an
// unusual stack alignment.
describe :: proc(plan: Abi_Plan) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for param in plan.params {
		switch param.attr {
		case .Direct:
			fmt.sbprintf(&builder, "%v", param.type)
			write_suffixes(&builder, param.ext, param.size, natural_bytes(param.type))
			if param.align != 8 && param.type != .V128 { fmt.sbprintf(&builder, "@%d", param.align) }
		case .Indirect:
			strings.write_string(&builder, "ind")
		case .By_Value:
			fmt.sbprintf(&builder, "byval(%d,%d)", param.size, param.align)
		case .Struct_Return:
			strings.write_string(&builder, "sret")
		case .Context:
			strings.write_string(&builder, "ctx")
		}
		strings.write_byte(&builder, ' ')
	}
	strings.write_string(&builder, "->")
	for result in plan.results {
		fmt.sbprintf(&builder, " %v", result.type)
		write_suffixes(&builder, result.ext, result.size, natural_bytes(result.type))
	}
	return strings.to_lower(strings.to_string(builder), context.temp_allocator)
}

write_suffixes :: proc(builder: ^strings.Builder, ext: Abi_Extension, size, natural: u32) {
	if ext == .Zero { strings.write_byte(builder, 'z') }
	if ext == .Sign { strings.write_byte(builder, 's') }
	if size != natural { fmt.sbprintf(builder, "/%d", size) }
}

// Expected plans come from the fork's `odin build -build-mode:llvm-ir` output for
// matching `proc "odin"`, `proc "contextless"`, `proc "c"` and `proc "stdcall"`
// signatures. The official compiler computes a result's extension but never
// attaches it to the function, so result "z"/"s" marks the intended extension and
// is the one thing the IR does not show.
@(test)
plan_matches_compiler :: proc(t: ^testing.T) {
	store := init()
	defer destroy(&store)
	defer free_all(context.temp_allocator)

	u8_ := scalar(&store, .Integer, 1)
	i8_ := intern(&store, Type{kind = .Integer, count = 1, signed = true})
	u16_ := scalar(&store, .Integer, 2)
	i16_ := intern(&store, Type{kind = .Integer, count = 2, signed = true})
	u32_ := scalar(&store, .Integer, 4)
	int_ := intern(&store, Type{kind = .Integer, count = 8, signed = true})
	u128_ := scalar(&store, .Integer, 16)
	f16_ := scalar(&store, .Float, 2)
	f32_ := scalar(&store, .Float, 4)
	f64_ := scalar(&store, .Float, 8)
	bool_ := scalar(&store, .Bool, 1)
	enum_i8 := intern(&store, Type{kind = .Enum, backing = i8_})
	enum_u16 := intern(&store, Type{kind = .Enum, backing = u16_})
	bits8 := intern(&store, Type{kind = .Bit_Set, backing = u8_})
	rawptr_ := intern(&store, Type{kind = .Raw_Pointer})
	pointer := intern(&store, Type{kind = .Pointer, elem = int_})
	cstring_ := intern(&store, Type{kind = .CString})
	string_ := intern(&store, Type{kind = .String})
	slice := intern(&store, Type{kind = .Slice, elem = int_})
	any_ := intern(&store, Type{kind = .Any})
	dynamic_ := intern(&store, Type{kind = .Dynamic_Array, elem = int_})
	map_ := intern(&store, Type{kind = .Map, elem = int_, index = int_})
	slice_like := record(&store, {}, rawptr_, int_)
	big := record(&store, {}, int_, int_, int_)
	pair := record(&store, {}, int_, int_)
	mixed := record(&store, {}, f32_, int_)
	byte_then_f64 := record(&store, {}, u8_, f64_)
	v2 := record(&store, {}, f32_, f32_)
	empty := record(&store, {})
	i128_struct := record(&store, {}, u128_)
	simd8 := intern(&store, Type{kind = .Simd_Vector, elem = f32_, count = 8})
	simd4 := intern(&store, Type{kind = .Simd_Vector, elem = f32_, count = 4})
	simd2 := intern(&store, Type{kind = .Simd_Vector, elem = f32_, count = 2})
	simd4_int := intern(&store, Type{kind = .Simd_Vector, elem = u32_, count = 4})
	simd8_wrapped := record(&store, {}, simd8)
	f64_pair := array_of(&store, f64_, 2)
	three_bytes := record(&store, {}, array_of(&store, u8_, 3))
	byte_short_byte := record(&store, {}, u8_, u16_, u8_)
	float_half := record(&store, {}, f32_, f16_)
	three_halves := array_of(&store, f16_, 3)
	O :: Calling_Convention.Odin
	N :: Calling_Convention.Contextless
	C :: Calling_Convention.C
	cases := []Plan_Case {
		{"o01 small ints", O, {u8_, i8_, bool_, enum_i8, enum_u16, bits8, i16_, u32_}, nil, nil, "i8z i8s i8z i8s i16z i8s i16s i32 ctx ->"},
		{"c01 small ints", C, {u8_, i8_, bool_, enum_i8, enum_u16, bits8, i16_, u32_}, nil, nil, "i8z i8s i8z i8s i16z i8s i16s i32 ->"},
		{
			"o02 slice-like out of registers",
			O,
			{string_, slice, any_, slice_like, cstring_, rawptr_},
			nil,
			nil,
			"ptr i64 ptr i64 ptr i64 byval(16,8) ptr ptr ctx ->",
		},
		{"c02", C, {string_, slice, any_, slice_like}, nil, nil, "ptr i64 ptr i64 ptr i64 byval(16,8) ->"},
		{"o13 slice-like fast path", O, {slice_like, string_, pointer}, nil, nil, "ptr i64 ptr i64 ptr ctx ->"},
		{"o03 memory is indirect", O, {big, dynamic_, map_}, nil, nil, "ind ind ind ctx ->"},
		{"c03 memory is byval", C, {big, dynamic_}, nil, nil, "byval(24,8) byval(40,8) ->"},
		{"o04 straddle", O, {int_, int_, int_, int_, int_, pair}, nil, nil, "i64 i64 i64 i64 i64 byval(16,8) ctx ->"},
		{"c04 straddle", C, {int_, int_, int_, int_, int_, pair}, nil, nil, "i64 i64 i64 i64 i64 byval(16,8) ->"},
		{"o05 scalar after exhaustion", O, {int_, int_, int_, int_, int_, int_, pair, int_}, nil, nil, "i64 i64 i64 i64 i64 i64 byval(16,8) i64 ctx ->"},
		{
			"o06 sse exhaustion",
			O,
			{f64_, f64_, f64_, f64_, f64_, f64_, f64_, f64_, f64_pair, f64_, v2},
			nil,
			nil,
			"f64 f64 f64 f64 f64 f64 f64 f64 byval(16,8) f64 byval(8,8) ctx ->",
		},
		{"o07 i128", O, {u128_, i128_struct}, nil, nil, "i64@16 i64 i64 i64 ctx ->"},
		{"c07 i128 straddle", C, {int_, int_, int_, int_, int_, u128_, u128_}, nil, nil, "i64 i64 i64 i64 i64 i64@16 i64 i64@16 i64 ->"},
		{"o08 wide simd", O, {simd8, simd4, simd8_wrapped}, nil, nil, "byval(32,32) v128 byval(32,32) ctx ->"},
		{"c08 wide simd", C, {simd8, simd4}, nil, nil, "byval(32,32) v128 ->"},
		{"o09 empty struct", O, {empty, int_}, nil, nil, "i64 ctx ->"},
		{"o10 pair", O, {pair, pair}, nil, nil, "i64 i64 i64 i64 ctx ->"},
		{"o11 #by_ptr", O, {int_, pair, f64_}, {true, true, false}, nil, "ind ind f64 ctx ->"},
		{"o12 mixed", O, {mixed, byte_then_f64}, nil, nil, "f32 i64 i64 f64 ctx ->"},
		{"o14 odd sizes", O, {three_bytes, byte_short_byte, float_half, three_halves}, nil, nil, "i32/3 i64/6 f64 f64/6 ctx ->"},
		{"o15 small simd", O, {simd2, simd4_int, f32_, f16_, enum_u16}, nil, nil, "f64 v128 f32 f16 i16z ctx ->"},
		{"r01 u8", O, nil, nil, {u8_}, "ctx -> i8z"},
		{"r02 bool", O, nil, nil, {bool_}, "ctx -> i8z"},
		{"r03 i16", O, nil, nil, {i16_}, "ctx -> i16s"},
		{"r04 bit_set", O, nil, nil, {bits8}, "ctx -> i8s"},
		{"r05 sret", O, nil, nil, {big}, "sret ctx ->"},
		{"r06 pair", O, nil, nil, {pair}, "ctx -> i64 i64"},
		{"r07 mixed", O, nil, nil, {mixed}, "ctx -> f32 i64"},
		{"r08 split u8", O, nil, nil, {int_, u8_}, "ptr ctx -> i8"},
		{"r09 split lowered tail", O, nil, nil, {int_, mixed}, "ptr ctx -> i64 i64"},
		{"r10 split two pointers", O, nil, nil, {int_, int_, f64_}, "ptr ptr ctx -> f64"},
		{"r11 split big first", O, nil, nil, {big, int_}, "ptr ctx -> i64"},
		{"r12 split sret", O, nil, nil, {int_, big}, "sret ptr ctx ->"},
		{"r13 string", O, nil, nil, {string_}, "ctx -> ptr i64"},
		{"r14 bare simd", O, nil, nil, {simd8}, "ctx -> v128 v128"},
		{"r15 wrapped simd", O, nil, nil, {simd8_wrapped}, "sret ctx ->"},
		{"r16 u128", O, nil, nil, {u128_}, "ctx -> i64 i64"},
		{"r18 v2", O, nil, nil, {v2}, "ctx -> f64"},
		{"r20 f16", O, nil, nil, {f16_}, "ctx -> f16"},
		{"q01 contextless split", N, {int_}, nil, {int_, int_}, "i64 ptr -> i64"},
		{"q02 contextless memory", N, {big}, nil, {big}, "sret ind ->"},
		{"k01 c u8", C, nil, nil, {u8_}, "-> i8z"},
		{"k02 c sret", C, nil, nil, {big}, "sret ->"},
		{"k03 c tuple", C, nil, nil, {int_, int_}, "-> i64 i64"},
		{"k04 c tuple mixed", C, nil, nil, {int_, f64_}, "-> i64 f64"},
		{"k06 c tuple memory", C, nil, nil, {big, int_}, "sret ->"},
		{"k08 stdcall", C, {pair, big}, nil, {u16_}, "i64 i64 byval(24,8) -> i16z"},
	}
	for test_case in cases {
		procedure := procedure_type(&store, test_case.convention, test_case.params, test_case.results)
		plan, err := plan_abi(&store, procedure, test_case.by_pointer)
		testing.expectf(t, err == .None, "%s: %v", test_case.name, err)
		testing.expectf(t, describe(plan) == test_case.expected, "%s: got %q, want %q", test_case.name, describe(plan), test_case.expected)
		destroy_plan(&plan)
	}

	variadic := procedure_type(&store, .C, {int_}, {int_}, true)
	plan, err := plan_abi(&store, variadic)
	testing.expect(t, err == .None && plan.variadic && describe(plan) == "i64 -> i64", "c vararg")
	destroy_plan(&plan)

	poisoned := procedure_type(&store, .Odin, {TYPE_POISON}, nil)
	_, poison_err := plan_abi(&store, poisoned)
	testing.expect(t, poison_err == .Poison, "poison parameter")
}

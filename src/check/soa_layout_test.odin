package check

import "core:mem"
import "core:testing"
import "oc:types"

// Phase 1 locks the `#soa` memory layout to the official compiler's table (probed in /tmp/soa_probe,
// /tmp/soa_bad1-6, /tmp/soa_p1): a fixed `#soa[N]T` spreads each element field into an `[N]` array, a
// `#soa[]T` spreads into multi-pointers plus a hidden length, and a `#soa[dynamic]T` adds capacity and
// allocator. Lowering does not exist yet, so these tests stop at size, alignment and field offsets.

// A minimal checker over a fresh store. Field slices live in the fixture arena, mirroring the checker
// arena that owns them in production: a slice literal would keep stack backing, which dangles once the
// fixture procedure returns. The runtime package is not collected, so dynamic arrays take the
// structural allocator fallback, which carries the same 16-byte size and 8-byte alignment.
@(private = "file")
Soa_Layout_Fixture :: struct {
	store:   types.Store,
	arena:   mem.Dynamic_Arena,
	checker: Type_Checker,
	elem:    types.Type_Id,
}

@(private = "file")
soa_layout_fixture :: proc(fixture: ^Soa_Layout_Fixture) {
	fixture.store = types.init()
	mem.dynamic_arena_init(&fixture.arena)
	fixture.checker = Type_Checker {
		store           = &fixture.store,
		arena_allocator = mem.dynamic_arena_allocator(&fixture.arena),
	}
	i32_type := types.intern(&fixture.store, types.Type{kind = .Integer, name = "i32", count = 4, signed = true})
	f32_type := types.intern(&fixture.store, types.Type{kind = .Float, name = "f32", count = 4})
	u8_type := types.intern(&fixture.store, types.Type{kind = .Integer, name = "u8", count = 1})
	fields := make([]types.Type_Field, 3, mem.dynamic_arena_allocator(&fixture.arena))
	fields[0] = {"a", i32_type}
	fields[1] = {"b", f32_type}
	fields[2] = {"c", u8_type}
	fixture.elem = types.intern(&fixture.store, types.Type{kind = .Struct, name = "S", fields = fields})
}

@(private = "file")
soa_fixture_destroy :: proc(fixture: ^Soa_Layout_Fixture) {
	types.destroy(&fixture.store)
	mem.dynamic_arena_destroy(&fixture.arena)
}

@(private = "file")
soa_fixture_layout :: proc(t: ^testing.T, fixture: ^Soa_Layout_Fixture, id: types.Type_Id, size, alignment: i64) -> bool {
	got_size, got_alignment, err := types.layout(&fixture.store, id)
	return testing.expectf(
		t,
		err == .None && got_size == size && got_alignment == alignment,
		"size %d align %d, want %d/%d",
		got_size,
		got_alignment,
		size,
		alignment,
	)
}

@(private = "file")
soa_fixture_offset :: proc(t: ^testing.T, fixture: ^Soa_Layout_Fixture, id: types.Type_Id, index: int, offset: i64) -> bool {
	got, err := types.field_offset(&fixture.store, id, index)
	return testing.expectf(t, err == .None && got == offset, "field %d offset %d, want %d", index, got, offset)
}

@(test)
soa_fixed_sizes_alignments_and_offsets_match_official :: proc(t: ^testing.T) {
	fixture: Soa_Layout_Fixture
	soa_layout_fixture(&fixture)
	defer soa_fixture_destroy(&fixture)
	store := &fixture.store
	checker := &fixture.checker
	elem := fixture.elem
	if testing.expect(t, soa_fixture_layout(t, &fixture, elem, 12, 4)) {
		soa_fixture_offset(t, &fixture, elem, 0, 0)
		soa_fixture_offset(t, &fixture, elem, 1, 4)
		soa_fixture_offset(t, &fixture, elem, 2, 8)
	}
	// Official table for S = {i32, f32, u8}: N=1 -> 12, N=2 -> 20, N=4 -> 36, N=8 -> 72, all align 4.
	for entry, index in ([4]struct {
			count:   i64,
			size:    i64,
			offsets: [3]i64,
		}{{1, 12, {0, 4, 8}}, {2, 20, {0, 8, 16}}, {4, 36, {0, 16, 32}}, {8, 72, {0, 32, 64}}}) {
		soa, valid := soa_struct(checker, elem, entry.count, .Fixed)
		if !testing.expectf(t, valid, "N=%d rejected", entry.count) { continue }
		_ = index
		if !soa_fixture_layout(t, &fixture, soa, entry.size, 4) { continue }
		for want, field in entry.offsets { soa_fixture_offset(t, &fixture, soa, field, want) }
	}
	// A named `[2]f32` element spreads under x/y: fixed is two `[4]f32` fields, 32 bytes align 4.
	f32_type := types.intern(store, types.Type{kind = .Float, name = "f32", count = 4})
	pair := types.intern(store, types.Type{kind = .Array, elem = f32_type, count = 2})
	named := types.reserve_nominal(store, .Named, "V2")
	types.complete_nominal(store, named, types.Type{kind = .Named, name = "V2", elem = pair})
	pair_soa, pair_valid := soa_struct(checker, named, 4, .Fixed)
	if testing.expect(t, pair_valid) {
		if soa_fixture_layout(t, &fixture, pair_soa, 32, 4) {
			soa_fixture_offset(t, &fixture, pair_soa, 0, 0)
			soa_fixture_offset(t, &fixture, pair_soa, 1, 16)
		}
		descriptor := types.get(store, pair_soa)
		testing.expect(t, len(descriptor.fields) == 2 && descriptor.fields[0].name == "x" && descriptor.fields[1].name == "y")
	}
}

@(test)
soa_slice_and_dynamic_layout_match_official :: proc(t: ^testing.T) {
	fixture: Soa_Layout_Fixture
	soa_layout_fixture(&fixture)
	defer soa_fixture_destroy(&fixture)
	store := &fixture.store
	checker := &fixture.checker
	elem := fixture.elem
	// Official: three 8-byte field pointers plus an 8-byte hidden length, 32 bytes align 8.
	slice, slice_valid := soa_struct(checker, elem, 0, .Slice)
	if testing.expect(t, slice_valid) {
		if soa_fixture_layout(t, &fixture, slice, 32, 8) {
			soa_fixture_offset(t, &fixture, slice, 0, 0)
			soa_fixture_offset(t, &fixture, slice, 1, 8)
			soa_fixture_offset(t, &fixture, slice, 2, 16)
			soa_fixture_offset(t, &fixture, slice, 3, 24)
		}
		descriptor := types.get(store, slice)
		testing.expect(t, len(descriptor.fields) == 4 && descriptor.fields[3].name == soa_hidden_len)
	}
	// Official: pointers plus length, capacity and a 16-byte allocator, 56 bytes align 8.
	dyn_soa, dyn_soa_valid := soa_struct(checker, elem, 0, .Dynamic)
	if testing.expect(t, dyn_soa_valid) {
		if soa_fixture_layout(t, &fixture, dyn_soa, 56, 8) {
			soa_fixture_offset(t, &fixture, dyn_soa, 0, 0)
			soa_fixture_offset(t, &fixture, dyn_soa, 1, 8)
			soa_fixture_offset(t, &fixture, dyn_soa, 2, 16)
			soa_fixture_offset(t, &fixture, dyn_soa, 3, 24)
			soa_fixture_offset(t, &fixture, dyn_soa, 4, 32)
			soa_fixture_offset(t, &fixture, dyn_soa, 5, 40)
		}
		descriptor := types.get(store, dyn_soa)
		allocator_size, allocator_alignment, allocator_err := types.layout(store, descriptor.fields[5].type)
		testing.expect(
			t,
			len(descriptor.fields) == 6 &&
			descriptor.fields[3].name == soa_hidden_len &&
			descriptor.fields[4].name == soa_hidden_cap &&
			descriptor.fields[5].name == "allocator" &&
			allocator_err == .None &&
			allocator_size == 16 &&
			allocator_alignment == 8,
		)
	}
	// A named `[2]f32` slice is two pointers plus length: 24 bytes align 8.
	f32_type := types.intern(store, types.Type{kind = .Float, name = "f32", count = 4})
	pair := types.intern(store, types.Type{kind = .Array, elem = f32_type, count = 2})
	pair_slice, pair_slice_valid := soa_struct(checker, pair, 0, .Slice)
	if testing.expect(t, pair_slice_valid) { soa_fixture_layout(t, &fixture, pair_slice, 24, 8) }
}

@(test)
soa_element_forms_match_official_accept_and_reject :: proc(t: ^testing.T) {
	fixture: Soa_Layout_Fixture
	soa_layout_fixture(&fixture)
	defer soa_fixture_destroy(&fixture)
	store := &fixture.store
	checker := &fixture.checker
	i32_type := types.intern(store, types.Type{kind = .Integer, name = "i32", count = 4, signed = true})
	_, scalar_valid := soa_struct(checker, i32_type, 4, .Fixed)
	testing.expect(t, !scalar_valid)
	_, slice_scalar_valid := soa_struct(checker, i32_type, 0, .Slice)
	testing.expect(t, !slice_scalar_valid)
	_, dyn_scalar_valid := soa_struct(checker, i32_type, 0, .Dynamic)
	testing.expect(t, !dyn_scalar_valid)
	f32_type := types.intern(store, types.Type{kind = .Float, name = "f32", count = 4})
	wide := types.intern(store, types.Type{kind = .Array, elem = f32_type, count = 5})
	_, wide_valid := soa_struct(checker, wide, 4, .Fixed)
	testing.expect(t, !wide_valid)
	// The official compiler accepts a struct element with string, nested struct and array fields.
	string_type := types.intern(store, types.Type{kind = .String})
	inner_fields := []types.Type_Field{{"v", i32_type}}
	inner := types.intern(store, types.Type{kind = .Struct, fields = inner_fields})
	array_field := types.intern(store, types.Type{kind = .Array, elem = i32_type, count = 8})
	mixed_fields := []types.Type_Field{{"text", string_type}, {"inner", inner}, {"fixed", array_field}}
	mixed := types.intern(store, types.Type{kind = .Struct, fields = mixed_fields})
	_, mixed_valid := soa_struct(checker, mixed, 4, .Fixed)
	testing.expect(t, mixed_valid)
	// The official compiler accepts an `#soa` of an `#soa`: the inner fields spread again, so each
	// outer field is a `[4]` array of the inner `[4]` field (144 bytes for the three-field element).
	elem := fixture.elem
	nested_inner, nested_inner_valid := soa_struct(checker, elem, 4, .Fixed)
	if testing.expect(t, nested_inner_valid) {
		nested, nested_valid := soa_struct(checker, nested_inner, 4, .Fixed)
		if testing.expect(t, nested_valid) { soa_fixture_layout(t, &fixture, nested, 144, 4) }
	}
}

@(test)
soa_formation_through_type_expressions_matches_official :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
S :: struct { a: i32, b: f32, c: u8 }
V2 :: [2]f32
main :: proc "contextless" () {
	#assert(size_of(#soa[1]S) == 12)
	#assert(size_of(#soa[2]S) == 20)
	#assert(size_of(#soa[4]S) == 36)
	#assert(size_of(#soa[8]S) == 72)
	#assert(align_of(#soa[4]S) == 4)
	#assert(offset_of(#soa[4]S, a) == 0)
	#assert(offset_of(#soa[4]S, b) == 16)
	#assert(offset_of(#soa[4]S, c) == 32)
	#assert(size_of(#soa[]S) == 32)
	#assert(align_of(#soa[]S) == 8)
	#assert(offset_of(#soa[]S, c) == 16)
	#assert(size_of(#soa[dynamic]S) == 56)
	#assert(align_of(#soa[dynamic]S) == 8)
	#assert(offset_of(#soa[dynamic]S, c) == 16)
	#assert(size_of(#soa[4]V2) == 32)
	#assert(offset_of(#soa[4]V2, y) == 16)
	#assert(size_of(#soa[]V2) == 24)
}
`,
	)
	_, ok := check_procedure_source(t, source, diagnostic_count = 0)
	testing.expect(t, ok)
}

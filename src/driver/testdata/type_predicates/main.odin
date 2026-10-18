package main

import "base:intrinsics"

Mode :: enum u8 {
	A,
	B,
}

Pair :: struct {
	a: u8,
	b: i32,
}

Holder :: struct {
	items: []u8,
}

Vec :: distinct [4]f32
Core :: intrinsics.type_core_type(Mode)
Base :: intrinsics.type_base_type(Vec)

main :: proc() {
	code := 0
	if intrinsics.type_is_comparable(Pair) { code += 1 }
	if !intrinsics.type_is_comparable(Holder) { code += 2 }
	if intrinsics.type_is_ordered(f32) { code += 4 }
	if !intrinsics.type_is_ordered(Pair) { code += 8 }
	if intrinsics.type_is_ordered_numeric(Mode) { code += 16 }
	if intrinsics.type_is_simple_compare(Pair) { code += 32 }
	if intrinsics.type_is_enumerated_array([Mode]f32) { code += 64 }
	if intrinsics.type_is_integer(Core) && intrinsics.type_is_array(Base) { code += 128 }
	intrinsics.syscall(60, uintptr(code))
}

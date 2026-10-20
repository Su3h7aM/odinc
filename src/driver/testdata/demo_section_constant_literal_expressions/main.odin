package main

import "base:intrinsics"

Bar :: struct {
	x, y: f32,
}

Foo :: struct {
	a, b:    int,
	using c: Bar,
}

FOO_CONST :: Foo {
	b = 2,
	a = 1,
	c = {3, 4},
}
ARRAY_CONST :: [3]int {
	1 = 4,
	2 = 9,
	0 = 1,
}

Baz :: enum {
	A = 5,
	B,
	C,
	D,
}

ENUM_ARRAY_CONST :: [Baz]int {
	.A ..= .C   = 1,
	.D = 16,
}

Negative_Baz :: enum {
	A = -2,
	B,
	C,
}

main :: proc() {
	code := FOO_CONST.a + FOO_CONST.b + int(FOO_CONST.x) + int(FOO_CONST.y)
	code += ARRAY_CONST[0] + ARRAY_CONST[1] + ARRAY_CONST[2]
	code += ENUM_ARRAY_CONST[.A] + ENUM_ARRAY_CONST[.D]
	values := [Baz]int {
		.A = 11,
		.B = 13,
		.C = 17,
		.D = 19,
	}
	index := Baz.B
	code += values[index]
	if len(values) != 4 { code += 512 }
	range_count := 0
	for value, key in values {
		range_count += 1
		if key == Baz.A && value != 11 { code += 16 }
		if key == Baz.B && value != 13 { code += 32 }
		if key == Baz.C && value != 17 { code += 64 }
		if key == Baz.D && value != 19 { code += 128 }
	}
	index_sum := 0
	for _, range_index in values { index_sum += int(range_index) }
	if range_count != 4 || index_sum != 26 { code += 256 }
	negative_values := [Negative_Baz]int {
		.A = 5,
		.B = 6,
		.C = 7,
	}
	negative_index := Negative_Baz.B
	code += negative_values[negative_index]
	negative_index_sum := 0
	for _, range_index in negative_values { negative_index_sum += int(range_index) }
	if len(negative_values) != 3 || negative_index_sum != -3 { code += 1024 }
	intrinsics.syscall(60, uintptr(code))
}

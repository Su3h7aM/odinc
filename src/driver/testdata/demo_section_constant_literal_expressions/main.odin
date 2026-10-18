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

main :: proc() {
	code := FOO_CONST.a + FOO_CONST.b + int(FOO_CONST.x) + int(FOO_CONST.y)
	code += ARRAY_CONST[0] + ARRAY_CONST[1] + ARRAY_CONST[2]
	code += ENUM_ARRAY_CONST[.A] + ENUM_ARRAY_CONST[.D]
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"

main :: proc() {
	m: matrix[2, 3]f32
	m = matrix[2, 3]f32{
		1, 9, -13,
		20, 5, -6,
	}
	elem := m[1, 2]
	b := matrix[2, 2]f32{}
	f := f32(3)
	b = f
	a := matrix[2, 3]f32{
		2, 3, 1,
		4, 5, 0,
	}
	bm := matrix[3, 2]f32{
		1, 2,
		3, 4,
		5, 6,
	}
	c := a * bm
	#assert(type_of(c) == matrix[2, 2]f32)
	code := int(elem) + int(c[0, 0]) + int(c[1, 1]) + int(b[0, 0])
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"

main :: proc() {
	code := 0
	m := matrix[2, 2]f32{
		1, 2,
		3, 4,
	}
	if m[0, 0] != 1 { code += 1 }
	if m[0, 1] != 2 { code += 2 }
	if m[1, 0] != 3 { code += 4 }
	if m[1, 1] != 4 { code += 8 }
	r := #row_major matrix[2, 3]i32{
		1, 2, 3,
		4, 5, 6,
	}
	if r[1, 2] != 6 { code += 16 }
	if r[1, 0] != 4 { code += 32 }
	c := matrix[2, 3]i32{
		1, 2, 3,
		4, 5, 6,
	}
	if c[1, 2] != 6 { code += 64 }
	intrinsics.syscall(60, uintptr(42 + code))
}

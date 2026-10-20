package main

import "base:intrinsics"

main :: proc() {
	code := 0
	ra := #row_major matrix[3, 4]f32{
		1e20, 1, -1e20, 1,
		0, 0, 0, 0,
		0, 0, 0, 0,
	}
	rb := #row_major matrix[4, 2]f32{
		1, 0,
		1, 0,
		1, 0,
		1, 0,
	}
	if (ra * rb)[0, 0] != 2 { code += 1 }
	ia := #row_major matrix[3, 4]i32{
		1, 2, 3, 4,
		5, 6, 7, 8,
		9, 10, 11, 12,
	}
	ib := #row_major matrix[4, 2]i32{
		1, 0,
		0, 1,
		1, 0,
		0, 1,
	}
	r := ia * ib
	if r[0, 0] != 4 || r[0, 1] != 6 || r[1, 0] != 12 || r[1, 1] != 14 || r[2, 0] != 20 || r[2, 1] != 22 {
		code += 2
	}
	intrinsics.syscall(60, uintptr(42 + code))
}

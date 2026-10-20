package main

import "base:intrinsics"

main :: proc() {
	code := 0
	a := matrix[2, 3]i32 {
		1 = 5,
	}
	if a[0, 1] != 5 { code += 1 }
	if a[0, 0] != 0 { code += 2 }
	if a[1, 2] != 0 { code += 4 }
	b := matrix[2, 2]i32 {
		0 = 1,
		3 = 4,
	}
	if b[0, 0] != 1 { code += 8 }
	if b[1, 1] != 4 { code += 16 }
	if b[0, 1] != 0 { code += 32 }
	r := #row_major matrix[2, 3]i32{1 = 5}
	if r[0, 1] != 5 { code += 64 }
	if r[1, 2] != 0 { code += 128 }
	intrinsics.syscall(60, uintptr(42 + code))
}

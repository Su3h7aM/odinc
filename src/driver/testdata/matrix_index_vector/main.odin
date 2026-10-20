package main

import "base:intrinsics"

main :: proc() {
	code := 0
	m := matrix[2, 3]i32{
		1, 2, 3,
		4, 5, 6,
	}
	c := m[1]
	if c[0] != 2 { code += 1 }
	if c[1] != 5 { code += 2 }
	r := #row_major matrix[2, 3]i32{
		1, 2, 3,
		4, 5, 6,
	}
	rr := r[1]
	if rr[0] != 4 { code += 4 }
	if rr[2] != 6 { code += 8 }
	i := 1
	j := 2
	if m[i, j] != 6 { code += 16 }
	k := 0
	q := m[k]
	if q[1] != 4 { code += 32 }
	m[1][0] = 20
	if m[0, 1] != 20 { code += 64 }
	m[i, 0] = 30
	if m[1, 0] != 30 { code += 128 }
	intrinsics.syscall(60, uintptr(42 + code))
}

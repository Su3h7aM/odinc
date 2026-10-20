package main

import "base:intrinsics"

main :: proc() {
	code := 0
	a := matrix[2, 2]i32{
		1, 2,
		3, 4,
	}
	b := matrix[2, 2]i32{
		5, 6,
		7, 8,
	}
	s := a + b
	if s[0, 0] != 6 || s[0, 1] != 8 || s[1, 0] != 10 || s[1, 1] != 12 { code += 1 }
	d := b - a
	if d[0, 0] != 4 || d[0, 1] != 4 || d[1, 0] != 4 || d[1, 1] != 4 { code += 2 }
	p := a * b
	if p[0, 0] != 19 || p[0, 1] != 22 || p[1, 0] != 43 || p[1, 1] != 50 { code += 4 }
	m2 := a * 2
	n := -a
	pp := +a
	t: i32 = 3
	m3 := t * a
	if m2[0, 0] != 2 || m2[1, 1] != 8 || m3[0, 1] != 6 || m3[1, 0] != 9 { code += 8 }
	if n[0, 0] != -1 || n[1, 1] != -4 || pp[0, 1] != 2 { code += 16 }
	q := a + 10
	if q[0, 0] != 11 || q[0, 1] != 2 || q[1, 0] != 3 || q[1, 1] != 14 { code += 32 }
	r := 10 - a
	if r[0, 0] != 9 || r[0, 1] != -2 || r[1, 0] != -3 || r[1, 1] != 6 { code += 64 }
	u := matrix[2, 2]i32{
		6, 3,
		5, 12,
	}
	v := u & 3
	if v[0, 0] != 2 || v[1, 1] != 0 { code += 128 }
	intrinsics.syscall(60, uintptr(42 + code))
}

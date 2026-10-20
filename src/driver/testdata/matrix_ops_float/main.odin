package main

import "base:intrinsics"

main :: proc() {
	code := 0
	a := matrix[2, 2]f32{
		1, 2,
		3, 4,
	}
	b := matrix[2, 2]f32{
		5, 6,
		7, 8,
	}
	s := a + b
	na := -a
	if s[0, 0] != 6 || s[1, 1] != 12 || na[0, 0] != -1 || na[1, 1] != -4 { code += 1 }
	p := a * b
	if p[0, 0] != 19 || p[0, 1] != 22 || p[1, 0] != 43 || p[1, 1] != 50 { code += 2 }
	m := matrix[2, 3]f32{
		1, 2, 3,
		4, 5, 6,
	}
	v := [3]f32{1, 1, 1}
	mv: [2]f32 = m * v
	if mv[0] != 6 || mv[1] != 15 { code += 4 }
	w := [2]f32{1, 1}
	vm: [3]f32 = w * m
	if vm[0] != 5 || vm[1] != 7 || vm[2] != 9 { code += 8 }
	n := matrix[3, 2]f32{
		7, 8,
		9, 10,
		11, 12,
	}
	c := m * n
	if c[0, 0] != 58 || c[0, 1] != 64 || c[1, 0] != 139 || c[1, 1] != 154 { code += 16 }
	sc: f32 = 2
	q := sc * a
	if q[0, 0] != 2 || q[1, 1] != 8 { code += 32 }
	r := a * 0.5
	if r[0, 0] != 0.5 || r[1, 1] != 2 { code += 64 }
	rm := #row_major matrix[2, 2]f32{
		1, 2,
		3, 4,
	}
	rn := #row_major matrix[2, 2]f32{
		5, 6,
		7, 8,
	}
	rp := rm * rn
	if rp[0, 0] != 19 || rp[1, 1] != 50 { code += 128 }
	ca := matrix[2, 2]complex64{
		complex(1, 2), complex(3, 4),
		complex(5, 6), complex(7, 8),
	}
	cb := ca + ca
	cp := ca * ca
	expected := matrix[2, 2]complex64{
		complex(-12, 42), complex(-16, 62),
		complex(-20, 98), complex(-24, 150),
	}
	if cb[1, 1] != complex(14, 16) || !(cp == expected) { code += 128 }
	intrinsics.syscall(60, uintptr(42 + code))
}

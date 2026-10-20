package main

import "base:intrinsics"

Holder :: struct {
	m: matrix[2, 2]f32,
}

gs: matrix[2, 2]i32 = 2

C :: f32(3)

main :: proc() {
	code := 0
	f := f32(3)
	a: matrix[2, 2]f32
	a = f
	b: matrix[2, 2]f32 = f
	d: matrix[2, 2]f32
	d = C
	if a[0, 0] != 3 ||
	   a[1, 1] != 3 ||
	   a[0, 1] != 0 ||
	   a[1, 0] != 0 ||
	   b[0, 0] != 3 ||
	   b[1, 1] != 3 ||
	   b[0, 1] != 0 ||
	   d[0, 0] != 3 ||
	   d[1, 1] != 3 ||
	   d[0, 1] != 0 { code += 1 }
	c: matrix[2, 2]i32 = -2
	z: matrix[2, 2]i32 = 0
	if c[0, 0] != -2 || c[1, 1] != -2 || c[0, 1] != 0 || z[0, 0] != 0 || z[1, 1] != 0 { code += 2 }
	k: matrix[2, 2]complex64 = 2
	cc := complex64(complex(1, 2))
	k2: matrix[2, 2]complex64
	k2 = cc
	if k[0, 0] != 2 || k[1, 1] != 2 || k[0, 1] != 0 || k2[0, 0] != cc || k2[1, 1] != cc || k2[0, 1] != 0 { code += 4 }
	h: matrix[2, 2]f16 = 1
	if h[0, 0] != 1 || h[1, 1] != 1 || h[0, 1] != 0 { code += 8 }
	p := &a
	p^ = f
	holder: Holder
	holder.m = f
	if a[0, 0] != 3 || a[0, 1] != 0 || holder.m[0, 0] != 3 || holder.m[1, 1] != 3 || holder.m[0, 1] != 0 { code += 16 }
	if gs[0, 0] != 2 || gs[1, 1] != 2 || gs[0, 1] != 0 { code += 32 }
	intrinsics.syscall(60, uintptr(42 + code))
}

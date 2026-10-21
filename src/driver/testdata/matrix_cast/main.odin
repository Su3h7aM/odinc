package main

import "base:intrinsics"

mat2 :: distinct matrix[2, 2]f32
mat3 :: distinct matrix[3, 3]f32
mat4 :: distinct matrix[4, 4]f32
mat2f64 :: distinct matrix[2, 2]f64
mat4x2f64 :: distinct matrix[4, 2]f64
mat2i :: distinct matrix[2, 2]i32
mat2c :: distinct matrix[2, 2]complex64
mat2x4 :: distinct matrix[2, 4]f32
mat4x2 :: distinct matrix[4, 2]f32
mat1x4 :: distinct matrix[1, 4]f32

main :: proc() {
	code := 0
	m2 := mat2{1, 3, 2, 4}
	m4 := mat4(m2)
	if m4[0, 0] != 1 ||
	   m4[1, 0] != 2 ||
	   m4[0, 1] != 3 ||
	   m4[1, 1] != 4 ||
	   m4[2, 2] != 1 ||
	   m4[3, 3] != 1 ||
	   m4[2, 0] != 0 ||
	   m4[0, 2] != 0 ||
	   m4[3, 0] != 0 ||
	   m4[0, 3] != 0 ||
	   m4[2, 1] != 0 ||
	   m4[3, 2] != 0 { code += 1 }
	if mat2(m4) != m2 { code += 2 }
	m3 := mat3(m2)
	if m3[0, 0] != 1 || m3[1, 0] != 2 || m3[0, 1] != 3 || m3[1, 1] != 4 || m3[2, 2] != 1 || m3[2, 0] != 0 || m3[0, 2] != 0 { code += 4 }
	d := mat2f64(m2)
	if d[0, 0] != 1 || d[1, 0] != 2 || d[0, 1] != 3 || d[1, 1] != 4 { code += 8 }
	e := mat2f64{1.5, 3.25, 2.5, 4.5}
	er := mat2{1.5, 3.25, 2.5, 4.5}
	if mat2(e) != er { code += 16 }
	i := mat2i(m2)
	if i[0, 0] != 1 || i[1, 0] != 2 || i[0, 1] != 3 || i[1, 1] != 4 { code += 32 }
	if mat2(i) != m2 { code += 64 }
	x := mat2x4{1, 3, 5, 7, 2, 4, 6, 8}
	y := mat4x2(x)
	if y[0, 0] != 1 || y[1, 0] != 2 || y[2, 0] != 3 || y[3, 0] != 4 || y[0, 1] != 5 || y[1, 1] != 6 || y[2, 1] != 7 || y[3, 1] != 8 { code += 128 }
	yr := mat4x2f64{1, 5, 2, 6, 3, 7, 4, 8}
	if mat4x2f64(x) != yr { code += 256 }
	q := mat1x4{7, 1, 4, 6}
	qr := mat2{7, 1, 0, 1}
	if mat2(q) != qr { code += 512 }
	c := mat2c(m2)
	if c[0, 0] != 1 || c[1, 0] != 2 || c[0, 1] != 3 || c[1, 1] != 4 { code += 1024 }
	b4 := mat4{1, 2, 0, 0, 3, 4, 0, 0, 5, 0, 6, 0, 0, 7, 0, 8}
	br := mat2{1, 2, 3, 4}
	if mat2(b4) != br { code += 2048 }
	intrinsics.syscall(60, uintptr(code))
}

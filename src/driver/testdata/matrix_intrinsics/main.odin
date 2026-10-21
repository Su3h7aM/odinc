package main

import "base:intrinsics"

M :: distinct matrix[2, 2]f32
V :: distinct [4]f32

calls: i32 = 0
seq: i32 = 0
left_at: i32 = -1
right_at: i32 = -1

track :: proc(m: ^matrix[2, 2]i32) -> ^matrix[2, 2]i32 {
	calls += 1
	return m
}

left_root :: proc(m: ^[2]i32) -> ^[2]i32 {
	left_at = seq
	seq += 1
	return m
}

right_root :: proc(a: ^[2]i32, b: ^[3]i32) -> ^[3]i32 {
	right_at = seq
	seq += 1
	a[0] = 100
	return b
}

main :: proc() {
	code := 0
	a := matrix[2, 2]i32{
		1, 2,
		3, 4,
	}
	b := matrix[2, 2]i32{
		-5, 1,
		9, -7,
	}
	c := intrinsics.hadamard_product(track(&a)^, track(&b)^)
	f := matrix[2, 2]f32{
		1, 2,
		3, 4,
	}
	g := matrix[2, 2]f32{
		2, 0,
		1, 3,
	}
	h := intrinsics.hadamard_product(f, g)
	if calls != 2 ||
	   c[0, 0] != -5 ||
	   c[0, 1] != 2 ||
	   c[1, 0] != 27 ||
	   c[1, 1] != -28 ||
	   h[0, 0] != 2 ||
	   h[0, 1] != 0 ||
	   h[1, 0] != 3 ||
	   h[1, 1] != 12 { code += 1 }
	x := [4]i32{1, 2, 3, 4}
	y := [4]i32{2, 0, 1, 3}
	z := intrinsics.hadamard_product(x, y)
	nm := M{1, 2, 3, 4}
	nn := M{2, 0, 1, 3}
	nc := intrinsics.hadamard_product(nm, nn)
	nv := V{1, 2, 3, 4}
	nw := V{2, 0, 1, 3}
	nz := intrinsics.hadamard_product(nv, nw)
	if z[0] != 2 || z[1] != 0 || z[2] != 3 || z[3] != 12 || nc[0, 0] != 2 || nc[1, 1] != 12 || nz[0] != 2 || nz[3] != 12 { code += 2 }
	b4 := matrix[4, 4]f32{
		1, 2, 0, 0,
		3, 4, 0, 0,
		5, 0, 6, 0,
		0, 7, 0, 8,
	}
	flat := intrinsics.matrix_flatten(b4)
	rm: #row_major matrix[2, 3]f32 = #row_major matrix[2, 3]f32{
		1, 2, 3,
		4, 5, 6,
	}
	fr := intrinsics.matrix_flatten(rm)
	if flat[0] != 1 ||
	   flat[1] != 3 ||
	   flat[5] != 4 ||
	   flat[7] != 7 ||
	   flat[10] != 6 ||
	   flat[15] != 8 ||
	   fr[0] != 1 ||
	   fr[1] != 2 ||
	   fr[2] != 3 ||
	   fr[3] != 4 ||
	   fr[4] != 5 ||
	   fr[5] != 6 { code += 4 }
	xx := [2]i32{1, 2}
	yy := [3]i32{10, 20, 30}
	o := intrinsics.outer_product(left_root(&xx)^, right_root(&xx, &yy)^)
	if left_at != 0 || right_at != 1 || o[0, 0] != 1000 || o[0, 2] != 3000 || o[1, 0] != 20 || o[1, 2] != 60 { code += 8 }
	nested := [2][2]f32{{1, 2}, {3, 4}}
	fn := intrinsics.matrix_flatten(nested)
	fb := intrinsics.matrix_flatten([4]bool{true, false, true, false})
	if fn[0][0] != 1 || fn[1][1] != 4 || !fb[0] || fb[1] || !fb[2] || fb[3] { code += 16 }
	i4 := matrix[2, 2]i32{
		1, 2,
		3, 4,
	}
	fi := intrinsics.matrix_flatten(i4)
	i4[1][0] = 99
	if fi[1] != 3 || i4[1][0] != 99 { code += 32 }
	f4 := matrix[2, 2]f32{
		1, 2,
		3, 4,
	}
	ff := intrinsics.matrix_flatten(f4)
	ff[1] = 3.5
	if ff[1] != 3.5 || f4[1][0] != 3 { code += 64 }
	intrinsics.syscall(60, uintptr(42 + code))
}

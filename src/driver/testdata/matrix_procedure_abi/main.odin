package main

import "base:intrinsics"

take22 :: proc(m: matrix[2, 2]f32) -> f32 {
	return m[0, 0] + m[0, 1] + m[1, 0] + m[1, 1]
}

take44 :: proc(m: matrix[4, 4]f32) -> f32 {
	return m[0, 0] + m[3, 3] + m[1, 2]
}

take22i :: proc(m: matrix[2, 2]i32) -> i32 {
	return m[0, 0] + m[0, 1] + m[1, 0] + m[1, 1]
}

take33 :: proc(m: matrix[3, 3]f32) -> f32 {
	return m[0, 0] + m[1, 1] + m[2, 2]
}

take11 :: proc(m: matrix[1, 1]f32) -> f32 {
	return m[0, 0]
}

make11 :: proc() -> matrix[1, 1]f32 {
	return matrix[1, 1]f32{
		7,
	}
}

make44 :: proc() -> matrix[4, 4]f32 {
	return matrix[4, 4]f32{
		1, 2, 3, 4,
		5, 6, 7, 8,
		9, 10, 11, 12,
		13, 14, 15, 16,
	}
}

mixed :: proc(m: matrix[2, 2]f32, a: int, b: f32, c: matrix[2, 2]f32) -> f32 {
	return m[0, 0] + f32(a) + b + c[1, 1]
}

Holder :: struct {
	field: matrix[2, 2]f32,
	tag:   int,
}

take_holder :: proc(s: Holder) -> f32 {
	return s.field[0, 0] + s.field[1, 1] + f32(s.tag)
}

take_row_major :: proc(m: #row_major matrix[2, 2]f32) -> f32 {
	return m[0, 0] + m[0, 1] + m[1, 0] + m[1, 1]
}

main :: proc() {
	code := 0
	if take22(matrix[2, 2]f32{
		   1, 2,
		   3, 4,
	   }) != 10 { code += 1 }
	if take44(matrix[4, 4]f32{
		   1, 2, 3, 4,
		   5, 6, 7, 8,
		   9, 10, 11, 12,
		   13, 14, 15, 16,
	   }) != 24 { code += 2 }
	if take22i(matrix[2, 2]i32{
		   1, 2,
		   3, 4,
	   }) != 10 { code += 4 }
	if take33(matrix[3, 3]f32{
		   1, 2, 3,
		   4, 5, 6,
		   7, 8, 9,
	   }) != 15 { code += 8 }
	if take11(matrix[1, 1]f32{
		   42,
	   }) != 42 { code += 16 }
	one := make11()
	if one[0, 0] != 7 { code += 32 }
	big := make44()
	if big[0, 0] != 1 || big[3, 3] != 16 || big[1, 2] != 7 { code += 64 }
	x := matrix[2, 2]f32{
		1, 2,
		3, 4,
	}
	y := matrix[2, 2]f32{
		10, 20,
		30, 40,
	}
	if mixed(x, 7, 2.5, y) != 50.5 { code += 128 }
	holder := Holder{matrix[2, 2]f32{
			1, 2,
			3, 4,
		}, 9}
	if take_holder(holder) != 14 {
		code += 256
	}
	if make11()[0, 0] != 7 { code += 512 }
	want_i11 := matrix[1, 1]i32{
		7,
	}
	if cast(matrix[1, 1]i32)make11() != want_i11 { code += 1024 }
	if make44()[0, 0] != 1 || make44()[3, 3] != 16 { code += 2048 }
	if (cast(matrix[4, 4]i32)make44())[1, 2] != 7 { code += 4096 }
	row := #row_major matrix[2, 2]f32{
		1, 2,
		3, 4,
	}
	if take_row_major(row) != 10 { code += 8192 }
	intrinsics.syscall(60, uintptr(code))
}

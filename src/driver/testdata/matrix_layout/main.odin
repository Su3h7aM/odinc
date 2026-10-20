package main

import "base:intrinsics"

Wrapped_Column :: struct {
	lead:  u8,
	value: matrix[3, 3]f32,
	tail:  u8,
}

Wrapped_Row :: struct {
	lead:  u8,
	value: #row_major matrix[2, 3]f64,
	tail:  u8,
}

main :: proc() {
	code := 0
	if size_of(matrix[3, 3]f32) != 36 { code += 1 }
	if align_of(matrix[3, 3]f32) != 4 { code += 2 }
	if size_of(matrix[2, 3]f64) != 48 { code += 4 }
	if align_of(matrix[2, 3]f64) != 16 { code += 8 }
	if size_of(#row_major matrix[2, 3]f64) != 48 { code += 16 }
	if align_of(#row_major matrix[2, 3]f64) != 8 { code += 32 }
	if size_of(Wrapped_Column) != 44 { code += 64 }
	if offset_of(Wrapped_Column, value) != 4 { code += 128 }
	if size_of(Wrapped_Row) != 64 { code += 256 }
	if offset_of(Wrapped_Row, value) != 8 { code += 512 }
	intrinsics.syscall(60, uintptr(42 + code))
}

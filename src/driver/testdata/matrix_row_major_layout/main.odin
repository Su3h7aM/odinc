package main

import "base:intrinsics"

Row_Major_2x3 :: #row_major matrix[2, 3]i32

main :: proc() {
	code := 0
	m := #row_major matrix[2, 3]i32{
		1, 2, 3,
		4, 5, 6,
	}
	if m[0, 0] != 1 || m[0, 1] != 2 || m[0, 2] != 3 { code += 1 }
	if m[1, 0] != 4 || m[1, 1] != 5 || m[1, 2] != 6 { code += 2 }
	n := Row_Major_2x3{1, 2, 3, 4, 5, 6}
	if n[0, 1] != 2 || n[1, 0] != 4 || n[1, 2] != 6 { code += 4 }
	plain := cast(matrix[2, 3]i32)m
	if plain[0, 1] != 2 || plain[1, 0] != 4 || plain[1, 2] != 6 { code += 8 }
	back := cast(#row_major matrix[2, 3]i32)plain
	if back[0, 2] != 3 || back[1, 0] != 4 || back[1, 1] != 5 { code += 16 }
	intrinsics.syscall(60, uintptr(code))
}

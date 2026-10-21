package main

import "base:intrinsics"

mat2 :: distinct matrix[2, 2]f32
mat4 :: distinct matrix[4, 4]f32

main :: proc() {
	code := 0
	m2 := mat2{1, 3, 2, 4}
	m4 := mat4(m2)
	m2b := mat2(m4)
	if m2b != m2 { code += 1 }
	intrinsics.syscall(60, uintptr(code))
}

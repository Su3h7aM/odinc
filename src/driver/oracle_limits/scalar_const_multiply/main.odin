package main

import "base:intrinsics"

C :: i32(3)

main :: proc() {
	code := 0
	m := matrix[2, 2]i32{
		1, 2,
		3, 4,
	}
	a := i32(3) * m
	if a[0, 0] != 3 || a[0, 1] != 6 || a[1, 0] != 9 || a[1, 1] != 12 { code += 1 }
	b := C * m
	if b[0, 0] != 3 || b[1, 1] != 12 { code += 2 }
	intrinsics.syscall(60, uintptr(42 + code))
}

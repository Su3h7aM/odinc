package main

import "base:intrinsics"

main :: proc() {
	values := [4]i32{10, 20, 30, 40}
	base := &values[0]
	code := int(intrinsics.ptr_offset(base, 2)^)
	code += intrinsics.ptr_sub(&values[3], &values[1])
	code += int(intrinsics.sqrt(f64(16)))
	code += int(intrinsics.sqrt(f32(9)))
	code += int(intrinsics.ptr_offset(&values[3], -2)^)
	intrinsics.syscall(60, uintptr(code))
}

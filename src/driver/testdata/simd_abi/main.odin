package main

import "base:intrinsics"
import "base:runtime"

Vector :: #simd[4]u32
Box :: struct {
	value: Vector,
}

direct :: #force_no_inline proc "c" (value: Vector) -> Vector {
	return intrinsics.simd_add(value, Vector{1, 2, 3, 4})
}

boxed :: #force_no_inline proc "c" (value: Box) -> Box {
	return Box{direct(value.value)}
}

stacked :: #force_no_inline proc "c" (a, b, c, d, e, f, g, h, i: Vector) -> Vector {
	return intrinsics.simd_add(a, i)
}

main :: proc() {
	code := 0
	value := direct(Vector{10, 20, 30, 40})
	if intrinsics.simd_extract(value, 0) == 11 && intrinsics.simd_extract(value, 3) == 44 { code += 1 }
	box := boxed(Box{Vector{2, 4, 6, 8}})
	if intrinsics.simd_extract(box.value, 1) == 6 && intrinsics.simd_extract(box.value, 2) == 9 { code += 2 }
	stack := stacked(value, value, value, value, value, value, value, value, box.value)
	if intrinsics.simd_extract(stack, 0) == 14 && intrinsics.simd_extract(stack, 3) == 56 { code += 4 }
	if intrinsics.simd_extract(value, 2) == 33 && intrinsics.simd_extract(box.value, 3) == 12 { code += 8 }
	state: runtime.Default_Random_State
	seed := [32]byte{}
	runtime.default_random_generator_proc(&state, .Reset, seed[:])
	bytes: [8]byte
	runtime.default_random_generator_proc(&state, .Read, bytes[:])
	if bytes[0] == 217 { code += 16 }
	if bytes[7] == 172 { code += 32 }
	intrinsics.syscall(60, uintptr(code))
}

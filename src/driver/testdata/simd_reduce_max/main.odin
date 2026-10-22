package main

import "base:intrinsics"

unsigned_max :: proc(value: #simd[4]u8) -> u8 {
	return intrinsics.simd_reduce_max(value)
}

signed_max :: proc(value: #simd[4]i32) -> i32 {
	return intrinsics.simd_reduce_max(value)
}

float_max :: proc(value: #simd[4]f32) -> f32 {
	return intrinsics.simd_reduce_max(value)
}

half_max :: proc(value: #simd[4]f16) -> f16 {
	return intrinsics.simd_reduce_max(value)
}

half_min :: proc(value: #simd[4]f16) -> f16 {
	return intrinsics.simd_reduce_min(value)
}

main :: proc() {
	assert(unsigned_max({3, 255, 128, 7}) == 255)
	assert(signed_max({-3, -7, -1, -5}) == -1)
	nan := transmute(f32)u32(0x7fc00000)
	assert(float_max({nan, -3, 7, nan}) == 7)
	all_nan := float_max({nan, nan, nan, nan})
	assert(all_nan != all_nan)
	negative_zero := transmute(f32)u32(0x80000000)
	assert(transmute(u32)float_max({negative_zero, negative_zero, negative_zero, negative_zero}) == 0x80000000)
	assert(transmute(u32)float_max({negative_zero, 0, negative_zero, 0}) == 0)
	assert(half_max({0.5, -2, 3, 1}) == 3)
	assert(half_min({0.5, -2, 3, 1}) == -2)
	tiny := transmute(f16)u16(1)
	normal := transmute(f16)u16(0x400)
	assert(half_min({normal, tiny, 0.5, 1}) == tiny)
	assert(half_max({tiny, normal, tiny, normal}) == normal)
	intrinsics.syscall(60, uintptr(0))
}

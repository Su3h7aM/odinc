package main

import "base:intrinsics"

mix :: proc(acc, value: u128) -> u128 {
	return acc * 31 + value
}

main :: proc() {
	acc: u128 = 0
	values := [?]u128{0x0123_4567_89ab_cdef_fedc_ba98_7654_3210, 0x40, u128(1) << 100, 0, u128(0xffff) << 64, u128(1)}
	for value in values {
		acc = mix(acc, u128(intrinsics.byte_swap(value)))
		acc = mix(acc, intrinsics.reverse_bits(value))
		acc = mix(acc, intrinsics.count_ones(value))
		acc = mix(acc, intrinsics.count_zeros(value))
		acc = mix(acc, intrinsics.count_leading_zeros(value))
		acc = mix(acc, intrinsics.count_trailing_zeros(value))
	}

	negative: i128 = -2
	acc = mix(acc, u128(intrinsics.byte_swap(negative)))
	acc = mix(acc, u128(intrinsics.count_ones(negative)))
	acc = mix(acc, u128(intrinsics.count_leading_zeros(negative)))

	folded := u64(acc) ~ u64(acc >> 64)
	intrinsics.syscall(60, uintptr(folded & 0xff))
}

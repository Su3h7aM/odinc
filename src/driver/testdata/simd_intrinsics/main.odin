package main

import "base:intrinsics"

main :: proc() {
	bytes: [17]u8
	for index in 0 ..< 17 {
		bytes[index] = u8(index)
	}
	loaded := intrinsics.unaligned_load(cast(^#simd[16]u8)&bytes[1])
	indices := intrinsics.simd_indices(#simd[16]u8)
	code := 0
	if intrinsics.simd_reduce_min(loaded) == 1 { code += 1 }
	different := intrinsics.simd_lanes_ne(loaded, indices)
	if intrinsics.simd_reduce_or(different) == 0xff { code += 2 }
	picked := intrinsics.simd_select(different, indices, loaded)
	if intrinsics.simd_reduce_or(picked) == 15 { code += 4 }
	same := intrinsics.simd_lanes_ne(loaded, loaded)
	if intrinsics.simd_reduce_min(intrinsics.simd_select(same, indices, loaded)) == 1 { code += 8 }
	bytes[1] = 100
	if intrinsics.simd_reduce_min(loaded) == 1 { code += 16 }
	splat: #simd[16]u8 = u8(7)
	if intrinsics.simd_reduce_or(splat) == 7 { code += 32 }
	intrinsics.syscall(60, uintptr(code))
}

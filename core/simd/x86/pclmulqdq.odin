#+build i386, amd64
package simd_x86

import "base:intrinsics"

@(require_results, enable_target_feature="pclmul")
_mm_clmulepi64_si128 :: #force_inline proc "c" (a, b: __m128i, $IMM8: u8) -> __m128i {
	return transmute(__m128i)intrinsics.x86_pclmulqdq(transmute(#simd[16]u8)a, transmute(#simd[16]u8)b, IMM8)
}
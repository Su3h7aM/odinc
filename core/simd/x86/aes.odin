#+build i386, amd64
package simd_x86

import "base:intrinsics"

@(require_results, enable_target_feature = "aes")
_mm_aesdec_si128 :: #force_inline proc "c" (a, b: __m128i) -> __m128i {
	return transmute(__m128i)intrinsics.x86_aesdec(transmute(#simd[16]u8)a, transmute(#simd[16]u8)b)
}

@(require_results, enable_target_feature = "aes")
_mm_aesdeclast_si128 :: #force_inline proc "c" (a, b: __m128i) -> __m128i {
	return transmute(__m128i)intrinsics.x86_aesdeclast(transmute(#simd[16]u8)a, transmute(#simd[16]u8)b)
}

@(require_results, enable_target_feature = "aes")
_mm_aesenc_si128 :: #force_inline proc "c" (a, b: __m128i) -> __m128i {
	return transmute(__m128i)intrinsics.x86_aesenc(transmute(#simd[16]u8)a, transmute(#simd[16]u8)b)
}

@(require_results, enable_target_feature = "aes")
_mm_aesenclast_si128 :: #force_inline proc "c" (a, b: __m128i) -> __m128i {
	return transmute(__m128i)intrinsics.x86_aesenclast(transmute(#simd[16]u8)a, transmute(#simd[16]u8)b)
}

@(require_results, enable_target_feature = "aes")
_mm_aesimc_si128 :: #force_inline proc "c" (a: __m128i) -> __m128i {
	return transmute(__m128i)intrinsics.x86_aesimc(transmute(#simd[16]u8)a)
}

@(require_results, enable_target_feature = "aes")
_mm_aeskeygenassist_si128 :: #force_inline proc "c" (a: __m128i, $IMM8: u8) -> __m128i {
	return transmute(__m128i)intrinsics.x86_aeskeygenassist(transmute(#simd[16]u8)a, IMM8)
}


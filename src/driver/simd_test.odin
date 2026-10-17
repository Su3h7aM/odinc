package driver

import "core:testing"

@(test)
simd_intrinsics_exit_with_lane_results :: proc(t: ^testing.T) {
	expect_exit(t, "simd_intrinsics", 63)
}

package main

import "base:intrinsics"

main :: proc() {
	_, _, feature_ecx, feature_edx := intrinsics.x86_cpuid(1, 0)
	sse_and_sse2 := (feature_edx >> 25) & 1 == 1 && (feature_edx >> 26) & 1 == 1
	xsave_state := true
	if (feature_ecx >> 27) & 1 == 1 {
		state_low, _ := intrinsics.x86_xgetbv(0)
		xsave_state = state_low & 0b11 == 0b11
	}
	first := intrinsics.read_cycle_counter()
	second := intrinsics.read_cycle_counter()
	monotonic := first != 0 && second >= first
	exit_code: uintptr
	if sse_and_sse2 { exit_code |= 1 }
	if xsave_state { exit_code |= 2 }
	if monotonic { exit_code |= 4 }
	intrinsics.syscall(60, exit_code)
}

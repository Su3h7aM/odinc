package main

import "base:intrinsics"

unreachable_result :: proc "contextless" () -> int {
	unreachable()
}

main :: proc "contextless" () {
	guard: bool = guard_value()
	if guard {
		unreachable()
	}
	intrinsics.syscall(60, 0)
}

guard_value :: proc "contextless" () -> bool {
	return 0 == 1
}

package main

import "base:intrinsics"

later: int = early + 1
early: int = seed_value()
counter: int = 0

seed_value :: proc "contextless" () -> int {
	return 41
}

main :: proc() {
	for _ in 0 ..< 3 {
		counter += later
	}
	intrinsics.syscall(60, uintptr(counter - 26))
}

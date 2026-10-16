package main

import "base:intrinsics"

add :: proc "contextless" (a, b: int) -> int {
	return a + b
}

main :: proc() {
	intrinsics.syscall(60, uintptr(add(2, 3)))
}

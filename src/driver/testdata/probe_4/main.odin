package main

import "base:intrinsics"

f :: proc "contextless" () -> int {
	total := 1
	if total == 1 {
		return 5
	}
	return 0
}

main :: proc() {
	r := f()
	intrinsics.syscall(60, uintptr(r))
}

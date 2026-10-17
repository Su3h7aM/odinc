package main

import "base:intrinsics"

f :: proc "contextless" () -> int {
	total := 1
	{
		defer total = total * 3
		total = total + 2
	}
	return total
}

main :: proc() {
	r := f()
	intrinsics.syscall(60, uintptr(r))
}

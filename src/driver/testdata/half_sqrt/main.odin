package main

import "base:intrinsics"

root :: proc(value: f16) -> f16 {
	return intrinsics.sqrt(value)
}

main :: proc() {
	assert(root(4) == 2 && root(0.25) == 0.5 && root(2) == f16(1.4142135623730951))
	intrinsics.syscall(60, uintptr(0))
}

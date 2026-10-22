package main

import "base:intrinsics"

mask :: proc(value: bool) -> u8 {
	return -u8(value)
}

main :: proc() {
	assert(mask(true) == 255 && mask(false) == 0)
	intrinsics.syscall(60, uintptr(0))
}

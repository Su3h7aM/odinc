package main

import "base:intrinsics"

main :: proc() {
	y: int
	y = 1
	intrinsics.syscall(60, uintptr(y))
}

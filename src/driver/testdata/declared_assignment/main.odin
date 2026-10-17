package main

import "base:intrinsics"

main :: proc "contextless" () {
	y: int
	y = 1
	intrinsics.syscall(60, uintptr(y))
}

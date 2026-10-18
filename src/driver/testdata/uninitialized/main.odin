package main

import "base:intrinsics"

main :: proc "contextless" () {
	value: int = ---
	value = 37
	intrinsics.syscall(60, uintptr(value))
}

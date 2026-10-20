package main

import "base:intrinsics"

main :: proc() {
	line := where_am_i()
	intrinsics.syscall(60, uintptr(line))
}

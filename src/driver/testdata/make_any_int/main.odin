package main

import "base:intrinsics"

main :: proc() {
	n: u32 = 3
	buf := make([]byte, n)
	intrinsics.syscall(60, uintptr(len(buf)))
}

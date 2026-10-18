package main

import "base:intrinsics"

main :: proc() {
	@(deprecated = "Use foo_v2 instead")
	foo_v1 :: proc(x: int) -> int {
		return x
	}
	foo_v2 :: proc(x: int) -> int {
		return x + 1
	}
	intrinsics.syscall(60, uintptr(foo_v2(4)))
}

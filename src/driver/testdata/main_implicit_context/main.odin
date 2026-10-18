package main

import "base:intrinsics"

main :: proc() {
	if context.allocator.procedure == nil {
		intrinsics.syscall(60, 3)
	}
}

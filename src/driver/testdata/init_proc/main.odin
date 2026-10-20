package main

import "base:intrinsics"
import "lib"

trace: int

@(init)
first_init :: proc "contextless" () { trace = lib.seen }

@(init)
second_init :: proc "contextless" () { trace = trace * 10 + 4 }

main :: proc() {
	intrinsics.syscall(60, uintptr(trace))
}

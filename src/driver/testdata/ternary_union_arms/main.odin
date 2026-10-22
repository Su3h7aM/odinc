package main

import "base:intrinsics"

Value :: union {
	u32,
	bool,
}

choose :: proc(first, second: u32, condition: bool) -> Value {
	return first if condition else second
}

main :: proc() {
	first := choose(3, 7, true)
	second := choose(3, 7, false)
	assert(first.(u32) == 3 && second.(u32) == 7)
	intrinsics.syscall(60, uintptr(0))
}

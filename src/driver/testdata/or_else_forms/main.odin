package main

import "base:intrinsics"

main :: proc() {
	value: union {
		int,
		f64,
	} = 8
	asserted := value.(int) or_else 3
	called := pair() or_else 9
	intrinsics.syscall(60, uintptr(asserted + called))
}

pair :: proc() -> (int, bool) { return 9, true }

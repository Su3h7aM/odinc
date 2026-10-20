package main

import "base:intrinsics"

Error :: enum {
	None,
	Failure,
}

main :: proc() {
	code := 0
	value: union {
		int,
		f64,
	} = 11
	for {
		n := value.(int) or_break
		code += n
		break
	}
	for {
		n := pair() or_break
		code += n
		break
	}
	outer: for {
		first, second := triple() or_continue outer
		code += first + second
		break outer
	}
	intrinsics.syscall(60, uintptr(code))
}

pair :: proc() -> (int, bool) { return 2, true }
triple :: proc() -> (int, int, Error) { return 6, 7, .None }

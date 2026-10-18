package main

import "base:intrinsics"

Error :: enum {
	None,
	Something_Bad,
}

caller_1 :: proc() -> Error {
	return .Something_Bad
}

caller_2 :: proc() -> (int, Error) {
	return 123, .None
}

caller_3 :: proc() -> (int, int, Error) {
	return 123, 345, .None
}

main :: proc() {
	code := 0
	for {
		caller_1() or_break
	}
	for {
		n := caller_2() or_break
		code += n
		break
	}
	loop: for {
		n := caller_2() or_break loop
		code += n
		break loop
	}
	i := 0
	for i < 5 {
		i += 1
		caller_1() or_continue
		code += 100
	}
	code += i
	for {
		x, y := caller_3() or_continue
		code += x + y
		break
	}
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"

Error :: enum {
	None,
	Something_Bad,
	Something_Worse,
	The_Worst,
	Your_Mum,
}

caller_1 :: proc() -> Error {
	return .None
}

caller_2 :: proc() -> (int, Error) {
	return 123, .None
}

caller_3 :: proc() -> (int, int, Error) {
	return 123, 345, .None
}

bad_caller :: proc() -> Error {
	return .Your_Mum
}

foo_1 :: proc() -> Error {
	n0, err := caller_2()
	if err != nil {
		return err
	}
	n1 := caller_2() or_return
	caller_1() or_return
	n0, n1 = caller_3() or_return
	_ = n0 + n1
	return .None
}

foo_2 :: proc() -> (n: int, err: Error) {
	x: int
	x, err = caller_2()
	if err != nil {
		return
	}
	y := caller_2() or_return
	_ = y
	caller_1() or_return
	if z, zerr := caller_2(); zerr != nil {
		return -345 * z, zerr
	}
	n = 123
	return
}

propagate :: proc() -> Error {
	bad_caller() or_return
	return .None
}

main :: proc() {
	code := 0
	if foo_1() == .None { code += 1 }
	n, err := foo_2()
	if err == .None { code += n }
	code += int(propagate())
	intrinsics.syscall(60, uintptr(code))
}

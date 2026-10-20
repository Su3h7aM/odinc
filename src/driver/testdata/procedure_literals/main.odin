package main

import "base:intrinsics"

apply :: proc "contextless" (callback: proc "contextless" (_: int) -> int, value: int) -> int {
	return callback(value)
}

main :: proc() {
	OFFSET :: 2
	add :: proc "contextless" (value: int) -> int { return value + OFFSET }
	factorial :: proc "contextless" (value: int) -> int {
		if value <= 1 { return 1 }
		return value * factorial(value - 1)
	}
	callback := proc "contextless" (value: int) -> int { return value * 3 }
	code := callback(add(5)) + factorial(4)
	code += apply(proc "contextless" (value: int) -> int { return value + 1 }, 5)
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"

add :: proc(left, right: $T) -> T {
	return left + right
}

main :: proc() {
	value: i64 = 20
	left := add(value, 3)
	right := add(4, value)
	intrinsics.syscall(60, uintptr(left + right))
}

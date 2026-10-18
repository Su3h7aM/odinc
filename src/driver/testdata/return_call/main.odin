package main

import "base:intrinsics"

pair :: proc() -> (int, int) {
	return 3, 4
}

forward :: proc() -> (int, int) {
	return pair()
}

main :: proc() {
	x, y := forward()
	intrinsics.syscall(60, uintptr(x * 10 + y))
}

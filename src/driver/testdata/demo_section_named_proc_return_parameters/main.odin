package main

import "base:intrinsics"

pair :: proc() -> (first, second: int) {
	first = 4
	second = 7
	return
}

main :: proc() {
	first, second := pair()
	code := 0
	if first == 4 && second == 7 { code = 11 }
	intrinsics.syscall(60, uintptr(code))
}

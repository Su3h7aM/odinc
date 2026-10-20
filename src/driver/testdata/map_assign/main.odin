package main

import "base:intrinsics"

main :: proc() {
	code := 0
	values: map[int]int
	values[7] = 19
	if values[7] != 19 { code += 1 }
	values[7] = 23
	if values[7] != 23 { code += 2 }
	intrinsics.syscall(60, uintptr(code))
}

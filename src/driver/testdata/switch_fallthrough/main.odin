package main

import "base:intrinsics"

main :: proc() {
	code := 0
	x := 1
	switch x {
	case 1:
		code += 1
		fallthrough
	case 2:
		code += 2
	case 3:
		code += 4
	}
	intrinsics.syscall(60, uintptr(code))
}

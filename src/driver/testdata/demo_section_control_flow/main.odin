package main

import "base:intrinsics"

main :: proc() {
	code := 0
	for i := 0; i < 5; i += 1 {
		if i == 2 { continue }
		code += i
	}
	values := [3]int{1, 2, 3}
	for value in values { code += value }
	switch code {
	case 14:
		code += 8
	case:
		code = 1
	}
	intrinsics.syscall(60, uintptr(code))
}

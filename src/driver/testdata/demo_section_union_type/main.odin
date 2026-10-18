package main

import "base:intrinsics"

Shape :: union {
	int,
	f64,
}

area :: proc(shape: Shape) -> int {
	switch value in shape {
	case int:
		return value
	case f64:
		return 7
	}
	return 0
}

main :: proc() {
	shape: Shape = 4
	code := area(shape) + area(f64(1))
	if _, ok := shape.(int); ok { code += 1 }
	intrinsics.syscall(60, uintptr(code))
}

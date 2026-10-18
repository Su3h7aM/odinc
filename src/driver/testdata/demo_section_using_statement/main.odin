#+feature using-stmt
package main

import "base:intrinsics"

Point :: struct {
	x, y: int,
}

main :: proc() {
	point := Point {
		x = 2,
		y = 5,
	}
	using point
	intrinsics.syscall(60, uintptr(x + y))
}

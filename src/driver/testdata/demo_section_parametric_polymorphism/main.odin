package main

import "base:intrinsics"

first :: proc(values: []$T) -> T {
	return values[0]
}

Pair :: struct($A, $B: typeid) {
	left:  A,
	right: B,
}

main :: proc() {
	numbers := [2]int{6, 9}
	pair := Pair(int, int) {
		left  = first(numbers[:]),
		right = 2,
	}
	intrinsics.syscall(60, uintptr(pair.left + pair.right))
}

package main

import "base:intrinsics"

sum :: proc "contextless" (base: int, values: ..int) -> int {
	result := base
	for value in values { result += value }
	return result
}

main :: proc() {
	values := [3]int{6, 7, 8}
	empty: []int
	result := sum(1, 2, 3) + sum(4) + sum(5, ..values[:]) + sum(9, ..empty)
	intrinsics.syscall(60, uintptr(result))
}

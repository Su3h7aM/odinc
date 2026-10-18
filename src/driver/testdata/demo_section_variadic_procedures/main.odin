package main

import "base:intrinsics"

sum :: proc(values: ..int) -> int {
	total := 0
	for value in values { total += value }
	return total
}

main :: proc() {
	numbers := [3]int{1, 2, 3}
	code := sum(1, 2) + sum(..numbers[:]) + sum()
	intrinsics.syscall(60, uintptr(code))
}

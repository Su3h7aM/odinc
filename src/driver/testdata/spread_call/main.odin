package main

import "base:intrinsics"

sum :: proc(first: int, nums: ..int, scale := 1) -> int {
	total := first
	for value in nums { total += value * scale }
	return total
}

main :: proc() {
	xs := []int{3, 4}
	first := sum(1, ..xs)
	second := sum(1, ..xs, scale = 2)
	intrinsics.syscall(60, uintptr(first + second))
}

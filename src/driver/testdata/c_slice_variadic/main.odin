package main

import "base:intrinsics"

sum :: proc "c" (base: int, values: ..int) -> int {
	result := base
	for value in values { result += value }
	return result
}

sum_float :: proc "c" (base: f64, values: ..f64) -> f64 {
	result := base
	for value in values { result += value }
	return result
}

main :: proc() {
	values := [3]int{6, 7, 8}
	empty: []int
	floats := [2]f64{2, 3}
	result := sum(1, 2, 3) + sum(4) + sum(5, ..values[:]) + sum(9, ..empty)
	result += int(sum_float(1, 2, 3) + sum_float(4) + sum_float(5, ..floats[:]))
	intrinsics.syscall(60, uintptr(result))
}

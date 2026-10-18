package main

import "base:intrinsics"

sum :: proc(values: ..int, scale := 1, offset := 0) -> int {
	total := 0
	for value in values { total += value }
	return total * scale + offset
}

main :: proc() {
	none := sum()
	plain := sum(1, 2, 3)
	scaled := sum(4, 5, scale = 2)
	shifted := sum(1, offset = 3)
	intrinsics.syscall(60, uintptr(none + plain + scaled + shifted))
}

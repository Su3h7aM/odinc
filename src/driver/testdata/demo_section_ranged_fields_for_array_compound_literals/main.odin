package main

import "base:intrinsics"

main :: proc() {
	code := 0
	foo := [?]int{1, 4, 9, 16}
	code += foo[0] + foo[1] + foo[2] + foo[3]
	indexed := [?]int {
		3 = 16,
		1 = 4,
		2 = 9,
		0 = 1,
	}
	code += indexed[3] + indexed[0]
	i := 2
	ranged := [?]int {
		0 = 123,
		5 ..= 9  = 54,
		10 ..< 16  = i * 3 + (i - 1) * 2,
	}
	code += ranged[10] + len(ranged)
	slice := []int {
		0 = 123,
		5 ..= 9  = 54,
		10 ..< 16  = i * 3 + (i - 1) * 2,
	}
	code += slice[10]
	intrinsics.syscall(60, uintptr(code))
}

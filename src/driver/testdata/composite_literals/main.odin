package main

import "base:intrinsics"

Pair :: struct {
	left, right: int,
}
Flags :: enum {
	A,
	B,
	C,
}
Levels :: enum {
	Low = 1,
	Mid,
	High,
}
ROWS :: [2]int{6, 7}

main :: proc() {
	input := 9
	pair: Pair = {input, 2}
	array: [3]int = {
		2 = input,
	}
	constant := [2]int{4, 5}
	mask := bit_set[Flags]{.A, .C}
	levels := #partial [Levels]int {
		.Mid  = 9,
		.High = 2,
	}
	slots := transmute([3]int)levels
	code := pair.left + pair.right + array[2] + constant[1] + int(transmute(u8)mask) + slots[1] + slots[2] + ROWS[1] + [2]int{input, 3}[input - 8]
	intrinsics.syscall(60, uintptr(code))
}

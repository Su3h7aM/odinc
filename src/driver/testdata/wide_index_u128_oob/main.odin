package main

import "base:intrinsics"

_WORD :: distinct u128
TABLE :: "0123456789abcdef"

main :: proc() {
	table := TABLE
	ceiling := max(u64)
	index := _WORD(ceiling) + _WORD(2)
	if table[index] != '1' { intrinsics.syscall(60, 1) }
}

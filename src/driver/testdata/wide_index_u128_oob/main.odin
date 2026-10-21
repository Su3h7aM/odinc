package main

_WORD :: distinct u128
TABLE :: "0123456789abcdef"

main :: proc() {
	ceiling := max(u64)
	index := _WORD(ceiling) + _WORD(1)
	_ = TABLE[index]
}

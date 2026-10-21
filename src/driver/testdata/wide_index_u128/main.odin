package main

import "base:intrinsics"

_WORD :: distinct u128
TABLE :: "0123456789abcdef"

main :: proc() {
	first := TABLE[_WORD(10)]
	high, low := _WORD(0x23), _WORD(0x10)
	quotient := high / low
	rest := high - quotient * low
	second := TABLE[rest]
	if first != 'a' || second != '3' {
		intrinsics.syscall(60, 1)
	}
	intrinsics.syscall(60, 42)
}

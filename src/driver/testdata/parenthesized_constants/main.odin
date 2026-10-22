package main

import "base:intrinsics"

scale :: proc(value: f64) -> f64 {
	return value * (1 << 3)
}

prefix :: proc(value: u8) -> u8 {
	return (1 << 5) | value
}

suffix :: proc(value: u8) -> u8 {
	return value | (4 << 5)
}

main :: proc() {
	assert(scale(2) == 16 && prefix(3) == 35 && suffix(3) == 131)
	intrinsics.syscall(60, uintptr(0))
}

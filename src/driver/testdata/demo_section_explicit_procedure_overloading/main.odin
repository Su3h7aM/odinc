package main

import "base:intrinsics"

add_int :: proc(a, b: int) -> int { return a + b }
add_f64 :: proc(a, b: f64) -> int { return 100 }

add :: proc {
	add_int,
	add_f64,
}

main :: proc() {
	code := add(2, 3)
	code += add(f64(1), f64(2)) - 100
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"

Buffer :: [max(2, 8, 4)]u8
calls: int

next :: proc "contextless" () -> int {
	calls += 1
	return calls
}

main :: proc "contextless" () {
	buffer: Buffer
	code := 0
	if len(buffer) == 8 && min(9, 5, 7, 6) == 5 { code += 1 }
	if abs(-17) == 17 && clamp(12, 2, 9) == 9 && clamp(-4, 2, 9) == 2 && clamp(1, 5, 0) == 5 { code += 2 }
	if min(1.5, 2.5) == 1.5 && abs(-2.5) == 2.5 && clamp(3.5, 1.5, 2.5) == 2.5 { code += 4 }
	value := u8(4)
	if max(2, value, 9, 1) == 9 && min(8, value, 7) == 4 { code += 8 }
	if min(next(), next(), next(), next()) == 1 && calls == 4 { code += 16 }
	negative_zero := transmute(f64)u64(0x8000_0000_0000_0000)
	if transmute(u64)abs(negative_zero) == 0 { code += 32 }
	if max(next(), next(), next(), next()) == 8 && calls == 8 { code += 64 }
	intrinsics.syscall(60, uintptr(code))
}

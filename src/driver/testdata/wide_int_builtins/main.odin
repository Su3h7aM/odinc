package main

import "base:intrinsics"

main :: proc() {
	code := int(abs(i128(-5)))
	big := i128(1) << 100
	code += int(abs(-big) >> 98)
	p := u128(1) << 63
	q := u128(1) << 64
	code += int(max(p, q) >> 62)
	code += int(min(p, q) >> 60)
	code += int(clamp(q, p, u128(1) << 65) >> 62)
	code += int(clamp(p, q, u128(1) << 65) >> 64)
	sn := -(i128(1) << 70)
	sp := i128(1) << 64
	code += int(abs(min(sn, sp)) >> 70)
	code += int(abs(max(sn, sp)) >> 64)
	code += int(abs(clamp(sn, sp, i128(1) << 80)) >> 64)
	intrinsics.syscall(60, uintptr(code))
}

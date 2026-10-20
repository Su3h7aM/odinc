package main

import "base:intrinsics"

classify :: proc(v: u128) -> int {
	switch v {
	case 0:
		return 1
	case 5:
		return 2
	case u128(1) << 64:
		return 4
	case (u128(1) << 64) + 3:
		return 8
	case:
		return 16
	}
}

sign :: proc(v: i128) -> int {
	switch v {
	case -1:
		return 32
	case:
		return 0
	}
}

main :: proc() {
	code := classify(0) + classify(5) + classify(u128(1) << 64) + classify((u128(1) << 64) + 3) + classify(7)
	code += sign(i128(-1)) + sign(i128(1) << 100)
	intrinsics.syscall(60, uintptr(code))
}

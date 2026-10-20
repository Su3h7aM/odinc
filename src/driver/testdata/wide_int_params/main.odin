package main

import "base:intrinsics"

half :: proc(u: u128, d: u128) -> (q: u128, r: u128) {
	return u / d, u % d
}

mixed :: proc(a: u128, b: i128, n: int, flag: bool) -> int {
	if flag { return int(a >> 96) + n + int(b) }
	return -1
}

triple :: proc(x: u128) -> u128 {
	return x * 3
}

square :: proc(x: u128) -> u128 {
	return x * x
}

main :: proc() {
	u := u128(1) << 100
	q, r := half(u, u128(7))
	folded := int(q >> 90) + int(r % 16)
	mixed_value := mixed(u, i128(-5), 3, true)
	tripled := triple(u)
	squared := square(u128(1) << 63)
	negated := -i128(-5)
	cmp := 0
	if u > q { cmp = 1 }
	code := folded + mixed_value + int(tripled >> 100) + int(negated) + cmp + int(squared >> 126)
	intrinsics.syscall(60, uintptr(code))
}

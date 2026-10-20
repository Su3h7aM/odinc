package main

import "base:intrinsics"

pair :: proc() -> (int, int) {
	return 3, 4
}

sum2 :: proc(a, b: int) -> int {
	return a + b
}

sum3 :: proc(a, b, c: int) -> int {
	return a + b + c
}

ssum :: proc(a, b: int, c: ^int) -> int {
	return a + b + c^
}

dflt :: proc(a, b: int, c := 10) -> int {
	return a + b + c
}

vsum :: proc(xs: ..int) -> int {
	total := 0
	for x in xs {
		total += x
	}
	return total
}

vmix :: proc(first: int, xs: ..int) -> int {
	total := first
	for x in xs {
		total += x
	}
	return total
}

sumg :: proc {
	sum2,
	sum3,
}

main :: proc() {
	code := 0
	code += sum2(pair())
	code += sum3(pair(), 5)
	n := 1
	code += ssum(pair(), &n)
	code += dflt(pair())
	code += sumg(pair())
	code += vsum(pair())
	code += vmix(pair())
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"

main :: proc() {
	code := 0
	a := matrix[2, 2]i32{
		1, 2,
		3, 4,
	}
	if !(a == a) { code += 1 }
	if a != a { code += 2 }
	b := matrix[2, 2]i32{
		1, 2,
		3, 5,
	}
	if a == b { code += 4 }
	if !(a != b) { code += 8 }
	c := matrix[2, 2]i32{
		1, 0,
		0, 1,
	}
	s: i32 = 1
	if !(c == s) { code += 16 }
	if !(s == c) { code += 32 }
	if c == 2 { code += 64 }
	if !(c != 2) { code += 128 }
	intrinsics.syscall(60, uintptr(42 + code))
}

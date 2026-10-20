package main

import "base:intrinsics"

main :: proc() {
	a := "abc"
	b := "abd"
	c: cstring = "abc"
	code := 0
	if a == "abc" { code += 1 }
	if a != b { code += 2 }
	if a < b { code += 4 }
	if b >= a { code += 8 }
	if "abc" <= a { code += 16 }
	if c == "abc" { code += 32 }
	intrinsics.syscall(60, uintptr(code))
}

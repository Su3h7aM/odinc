package main

import "base:intrinsics"

main :: proc() {
	empty: cstring = ""
	value: cstring = "abc"
	code := 0
	if empty == "" { code += 1 }
	if value == "abc" { code += 2 }
	intrinsics.syscall(60, uintptr(code))
}

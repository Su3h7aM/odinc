package main

import "base:intrinsics"

main :: proc "contextless" () {
	tag := "b"
	code := 0
	switch tag {
	case "a":
		code = 1
	case "b":
		code = 2
	case:
		code = 3
	}
	c: cstring = "z"
	switch c {
	case "y":
		code += 10
	case "z":
		code += 1
	}
	intrinsics.syscall(60, uintptr(code))
}

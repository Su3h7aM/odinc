package main

import "base:intrinsics"

main :: proc() {
	text := "abc"
	intrinsics.syscall(60, uintptr(len(text) * 10 + int(text[1])))
}

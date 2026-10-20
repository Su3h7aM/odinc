package main

import "base:intrinsics"

main :: proc() {
	c := cstring("Hellope")
	t := string(c)
	code := len(c) * 10 + len(t)
	intrinsics.syscall(60, uintptr(code))
}

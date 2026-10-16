package main

import "base:intrinsics"

narrow :: proc "contextless" (value: u8) -> u8 {
	return value
}

main :: proc() {
	flag := true
	count := 0
	if flag {
		count = int(narrow(200))
	}
	when false {
		count = 0
	}
	intrinsics.syscall(60, uintptr(count))
}

package main

import "base:intrinsics"

before :: proc "contextless" (a, b: [^]byte) -> bool { return a < b }

main :: proc() {
	buffer: [10]byte
	low := ([^]byte)(&buffer[0])
	high := ([^]byte)(&buffer[9])
	code := 0
	if before(low, high) { code += 1 }
	if high > low { code += 2 }
	if low <= low && high >= high { code += 4 }
	intrinsics.syscall(60, uintptr(code))
}

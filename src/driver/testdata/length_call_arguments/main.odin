package main

import "base:intrinsics"

lengths :: proc(first, second: uint) -> uint { return first * 10 + second }

main :: proc() {
	values: [4]u8
	window := values[1:3]
	result := lengths(len(window), len(values))
	result += lengths(second = len(window), first = len(values))
	intrinsics.syscall(60, uintptr(result))
}

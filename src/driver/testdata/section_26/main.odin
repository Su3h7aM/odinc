package main

import "base:intrinsics"

main :: proc() {
	values: [4]int
	values[0] = 1
	values[1] = 2
	values[2] = 3
	i := 3
	values[i] = 7
	copy_values := values
	copy_values[0] = 10
	window := values[1:3]
	tail := window[1:]
	intrinsics.syscall(60, uintptr(values[0] + copy_values[0] + window[0] + tail[0] + len(window) * 10 + len(values) + values[i]))
}

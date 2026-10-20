package main

import "base:intrinsics"

main :: proc() {
	buffer: [6]u8
	#no_bounds_check for i in 0 ..< 5 {
		buffer[i] = u8('a' + i)
	}
	buffer[5] = '\n'
	intrinsics.syscall(1, 1, uintptr(&buffer), 6)
	intrinsics.syscall(60, 0)
}

package main

import "base:intrinsics"

main :: proc "contextless" () {
	buffer: [8]u8
	source: [8]u8
	source[0] = 7
	source[1] = 9
	intrinsics.mem_copy_non_overlapping(&buffer, &source, 8)
	intrinsics.mem_copy(&buffer[1], &buffer[0], 2)
	code := 0
	if intrinsics.expect(buffer[1] == 7 && buffer[2] == 9, true) { code += 1 }
	intrinsics.mem_zero(&buffer[0], 1)
	if buffer[0] == 0 { code += 2 }
	intrinsics.mem_zero_volatile(&buffer, 8)
	if buffer[1] == 0 && buffer[2] == 0 { code += 4 }
	intrinsics.cpu_relax()
	if code == 0 { intrinsics.debug_trap() }
	if code == 0 { intrinsics.trap() }
	intrinsics.syscall(60, uintptr(code))
}

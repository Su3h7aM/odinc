package main

import "base:intrinsics"

Buffer :: [intrinsics.constant_log2(256)]u8

main :: proc "contextless" () {
	buffer: Buffer
	code := 0
	if len(buffer) == 8 { code += 1 }
	if intrinsics.constant_log2(0) == -1 { code += 2 }
	if intrinsics.constant_log2(1) == 0 && intrinsics.constant_log2(31) == 4 { code += 4 }
	if intrinsics.constant_log2(-32) == 5 { code += 8 }
	if intrinsics.constant_log2(1 << 100) == 100 { code += 16 }
	intrinsics.syscall(60, uintptr(code))
}

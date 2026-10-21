package main

import "base:intrinsics"

main :: proc() {
	buffer := intrinsics.alloca(64, 16)[:64]
	for i in 0 ..< 64 { buffer[i] = u8(i * 3) }
	acc := 0
	for b in buffer { acc += int(b) }
	code := 0
	if intrinsics.unlikely(acc == 6048) { code += 1 }
	if intrinsics.likely(acc == 6048) { code += 2 }
	if !intrinsics.unlikely(acc != 6048) { code += 4 }
	intrinsics.syscall(60, uintptr(code))
}

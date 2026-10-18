package main

import "base:intrinsics"

Pair :: struct {
	left, right: u64,
}

main :: proc() {
	buffer: [80]u8
	integer := cast(^u64)rawptr(&buffer[1])
	intrinsics.unaligned_store(integer, 0x0123456789abcdef)
	if intrinsics.unaligned_load(integer) != 0x0123456789abcdef { intrinsics.syscall(60, 1) }
	if buffer[0] != 0 || buffer[1] != 0xef || buffer[8] != 1 || buffer[9] != 0 { intrinsics.syscall(60, 2) }
	floating := cast(^f64)rawptr(&buffer[11])
	intrinsics.unaligned_store(floating, 3.5)
	if intrinsics.unaligned_load(floating) != 3.5 { intrinsics.syscall(60, 3) }
	pair: Pair
	pair.left = 17
	pair.right = 29
	aggregate := cast(^Pair)rawptr(&buffer[21])
	intrinsics.unaligned_store(aggregate, pair)
	copied := intrinsics.unaligned_load(aggregate)
	if copied.left != 17 || copied.right != 29 { intrinsics.syscall(60, 4) }
	intrinsics.syscall(60, 73)
}

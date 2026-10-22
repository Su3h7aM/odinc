package main

import "base:intrinsics"

counter: int
table: [4]int
base: int = 3
@(thread_local)
local_seed: int

main :: proc() {
	local_seed = 7
	for _ in 0 ..< 10 {
		counter += 1
	}
	for index in 0 ..< 4 {
		table[index] = index * base
	}
	code := counter + table[3] + local_seed
	intrinsics.syscall(60, uintptr(code))
}

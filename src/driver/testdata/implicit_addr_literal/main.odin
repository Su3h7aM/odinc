package main

import "base:intrinsics"

Record :: struct {
	x: int,
}

set :: proc(value: ^Record) {
	if value.x != 3 { intrinsics.syscall(60, 1) }
}

main :: proc() {
	set(&{x = 3})
	value: ^Record = &{x = 3}
	if value.x != 3 { intrinsics.syscall(60, 2) }
	intrinsics.syscall(60, 0)
}

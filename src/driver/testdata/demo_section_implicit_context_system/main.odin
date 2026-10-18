package main

import "base:intrinsics"

Marker :: struct {
	value: int,
}

bump :: proc(amount: int) {
	marker := cast(^Marker)context.user_ptr
	marker.value += amount
}

main :: proc() {
	marker := Marker {
		value = 1,
	}
	context.user_ptr = &marker
	bump(4)
	intrinsics.syscall(60, uintptr(marker.value))
}

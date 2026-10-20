package main

import "base:intrinsics"

Base :: struct {
	value: int,
}
Derived :: struct {
	before:     int,
	using base: Base,
	after:      int,
}

base_pointer :: proc(value: ^Derived) -> ^Base {
	return value
}

main :: proc() {
	derived := Derived {
		before = 100,
		base = {value = 29},
		after = 3,
	}
	base := base_pointer(&derived)
	base.value += 8
	assigned: ^Base = &derived
	assigned.value += 1
	result := derived.base.value
	if derived.before != 100 || derived.after != 3 { result = 99 }
	intrinsics.syscall(60, uintptr(result))
}

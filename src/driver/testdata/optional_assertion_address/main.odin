package main

import "base:intrinsics"

Value :: union {
	int,
	bool,
}

increment :: proc(value: ^Value) -> bool {
	pointer, ok := &value.(int)
	if ok { pointer^ += 1 } else { assert(pointer == nil) }
	return ok
}

main :: proc() {
	value: Value = 4
	assert(increment(&value) && value.(int) == 5)
	value = true
	assert(!increment(&value))
	pointer: ^int
	ok: bool
	pointer, ok = &value.(int)
	assert(pointer == nil && !ok)
	intrinsics.syscall(60, uintptr(0))
}

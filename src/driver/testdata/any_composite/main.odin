package main

import "base:intrinsics"

main :: proc() {
	x := 7
	a := any{&x, typeid_of(int)}
	code := 1
	if a.id == typeid_of(int) { code = 5 }
	if a.data == rawptr(&x) { code += 1 }
	intrinsics.syscall(60, uintptr(code))
}

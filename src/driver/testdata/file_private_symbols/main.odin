package main

import "base:intrinsics"
import "values"

main :: proc() {
	assert(values.first() == 11 && values.second() == 31)
	intrinsics.syscall(60, uintptr(values.first() + values.second()))
}

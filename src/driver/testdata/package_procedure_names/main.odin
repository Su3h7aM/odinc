package main

import alpha "a"
import beta "b"
import "base:intrinsics"

main :: proc() {
	intrinsics.syscall(60, uintptr(alpha.value() + beta.value()))
}

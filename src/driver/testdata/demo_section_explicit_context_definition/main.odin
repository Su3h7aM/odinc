package main

import "base:intrinsics"
import "base:runtime"

dummy_procedure :: proc() -> int {
	return 7
}

explicit_context_definition :: proc "c" () -> int {
	context = runtime.default_context()
	return dummy_procedure()
}

main :: proc() {
	intrinsics.syscall(60, uintptr(explicit_context_definition()))
}

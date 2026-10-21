package lib

import "base:intrinsics"
import "base:runtime"

code: int

Box :: struct {
	items: [dynamic]int,
}

Handle := &Box{}

@(init)
setup :: proc "contextless" () {
	context = runtime.default_context()
	append(&Handle.items, 10, 20)
	if len(Handle.items) != 2 {
		code += 128
	}
}

@(fini)
teardown :: proc "contextless" () {
	context = runtime.default_context()
	if len(Handle.items) != 2 {
		code += 4
	} else if Handle.items[0] != 10 || Handle.items[1] != 20 {
		code += 4
	}
	delete(Handle.items)
	code += 8
	intrinsics.syscall(60, uintptr(code))
}

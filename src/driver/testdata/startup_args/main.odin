package main

import "base:intrinsics"
import "core:os"

main :: proc() {
	if len(os.args) != 3 { intrinsics.syscall(60, 1) }
	if os.args[1] == "first" {
		value, found := os.lookup_env("NABLA_STARTUP_TEST", context.temp_allocator)
		if os.args[2] != "second" || !found || value != "present" { intrinsics.syscall(60, 1) }
	} else if os.args[1] == "third" {
		_, found := os.lookup_env("NABLA_STARTUP_TEST", context.temp_allocator)
		if os.args[2] != "fourth" || found { intrinsics.syscall(60, 1) }
	} else {
		intrinsics.syscall(60, 1)
	}
	intrinsics.syscall(60, 0)
}

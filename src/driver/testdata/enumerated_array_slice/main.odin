package main

import "base:intrinsics"
import "core:slice"

Key :: enum {
	First = 4,
	Second,
}

main :: proc() {
	values := [Key]int {
		.First  = 3,
		.Second = 5,
	}
	values_slice := slice.enumerated_array(&values)
	code := 42
	if len(values_slice) != 2 || values_slice[0] != 3 || values_slice[1] != 5 { code += 1 }
	intrinsics.syscall(60, uintptr(code))
}

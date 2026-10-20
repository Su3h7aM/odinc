package main

import "base:intrinsics"

named :: proc() -> string {
	NAME :: #procedure
	return NAME
}

generic :: proc(value: $T) -> string {
	return #procedure
}

main :: proc() {
	inner :: proc() -> string { return #procedure }
	callback := proc() -> string { return #procedure }
	result := 37
	if named() != "named" || generic(1) != "generic" || inner() != "inner" || callback() != "(anonymous-procedure)" || #procedure != "main" {
		result = 99
	}
	intrinsics.syscall(60, uintptr(result))
}

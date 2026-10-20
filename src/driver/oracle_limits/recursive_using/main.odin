#+feature using-stmt
package main

import "base:intrinsics"

Recursive :: struct {
	using next: ^Recursive,
}

main :: proc() {
	value: Recursive
	using value
	if next == nil { intrinsics.syscall(60, 43) }
}

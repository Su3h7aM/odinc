package main

import "base:intrinsics"

entry_point_call :: proc() {
	intrinsics.__entry_point()
}

main :: proc() {
	intrinsics.syscall(60, 7)
}

package main

import "base:intrinsics"

@(link_name = "nabla_ready")
ready: int

@(init)
mark_ready :: proc() {
	ready = 5
}

@(fini)
finish :: proc() {
	intrinsics.syscall(60, uintptr(ready))
}

main :: proc() {
}

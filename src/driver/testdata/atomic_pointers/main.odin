package main

import "base:intrinsics"

Node :: struct {
	value: int,
}

main :: proc() {
	first := Node {
		value = 3,
	}
	second := Node {
		value = 4,
	}
	link: ^Node = &first
	intrinsics.atomic_store_explicit(&link, &second, .Release)
	exit_code := intrinsics.atomic_load_explicit(&link, .Acquire).value
	intrinsics.atomic_store_explicit(&link, nil, .Release)
	if intrinsics.atomic_load_explicit(&link, .Acquire) == nil {
		exit_code += 10
	}
	intrinsics.syscall(60, uintptr(exit_code))
}

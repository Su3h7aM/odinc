package main

import "base:intrinsics"

Empty :: struct {}

Tagged :: union {
	int,
	Empty,
}

classify :: proc(value: Tagged) -> int {
	#partial switch v in value {
	case Empty:
	case int:
		return int(v)
	}
	return 10
}

main :: proc() {
	empty: Empty
	literal := Empty{}
	_ = empty
	_ = literal
	seven := 7
	tagged: Tagged = seven
	empty_tagged: Tagged = literal
	intrinsics.syscall(60, uintptr(classify(tagged) + classify(empty_tagged)))
}

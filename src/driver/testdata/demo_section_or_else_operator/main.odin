package main

import "base:intrinsics"

main :: proc() {
	v: union {
		int,
		f64,
	}
	i: int
	i = v.(int) or_else 123
	i = v.? or_else 123
	m: Maybe(int)
	j := m.? or_else 45
	intrinsics.syscall(60, uintptr(i + j))
}

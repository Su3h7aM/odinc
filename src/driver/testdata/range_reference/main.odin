package main

import "base:intrinsics"

S :: struct {
	a, b: int,
}

main :: proc() {
	code := 0

	fixed: #soa[2][3]u16
	for &v, i in fixed {
		v[0] = u16(i + 1)
		v[2] = u16((i + 1) * 2)
	}
	for &c, j in fixed[0] { c += u16(j) }
	#reverse for &c in fixed[1] { c += 1 }
	for e in fixed {
		for c in e { code += int(c) }
	}

	dyn := make(#soa[dynamic][3]u16, 2)
	defer delete(dyn)
	for &v in dyn { v[1] = 7 }
	for v in dyn {
		for c in v { code += int(c) }
	}

	s := fixed[:]
	for &v in s { v[1] += 1 }
	for v in s {
		for c in v { code += int(c) }
	}

	st: #soa[2]S
	for &e, i in st {
		e.a = i + 1
		e.b = (i + 1) * 10
	}
	for e in st { code += e.a + e.b }

	nested: #soa[2][2]u16
	for &e in nested {
		for &c in e { c = 3 }
	}
	for e in nested {
		for c in e { code += int(c) }
	}

	intrinsics.syscall(60, uintptr(code))
}

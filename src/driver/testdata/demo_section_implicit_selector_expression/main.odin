package main

import "base:intrinsics"

main :: proc() {
	Foo :: enum {
		A,
		B,
		C,
	}
	f: Foo
	f = Foo.A
	f = .A

	BAR :: bit_set[Foo]{.B, .C}
	code := 0
	switch f {
	case .A:
		code += 1
	case .B, .C:
		code += 100
	}
	if .B in BAR && .C in BAR { code += 2 }

	intrinsics.syscall(60, uintptr(code))
}

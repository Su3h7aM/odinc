package main

import "base:intrinsics"

main :: proc() {
	code := 0
	{
		Foo :: enum {
			A,
			B,
			C,
			D,
		}
		f := Foo.A
		switch f {
		case .A:
			code += 1
		case .B:
			code += 2
		case .C:
			code += 4
		case .D:
			code += 8
		case:
			code += 16
		}
		#partial switch f {
		case .A:
			code += 0
		case .D:
			code += 32
		}
	}
	{
		Foo :: union {
			int,
			bool,
		}
		f: Foo = 123
		switch _ in f {
		case int:
			code += 4
		case bool:
			code += 8
		case:
			code += 16
		}
		#partial switch _ in f {
		case bool:
			code += 64
		}
	}
	intrinsics.syscall(60, uintptr(code))
}

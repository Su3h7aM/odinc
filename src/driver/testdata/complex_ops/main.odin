package main

import "base:intrinsics"

twice :: proc(c: complex128) -> complex128 {
	return c + c
}

main :: proc() {
	a: complex128 = complex(1.0, 2.0)
	b: complex128 = 3 + 4i
	p := a * b
	q := a + b
	r := b - a
	h: complex128 = b / complex(2, 0)
	code := 0
	code += int(real(p)) + 10
	code += int(imag(p))
	code += int(real(q))
	code += int(imag(r))
	code += int(real(h) * 2)
	code += int(imag(h))
	if a == complex(1, 2) { code += 1 }
	if a != b { code += 2 }
	c64 := complex64(p)
	code += int(imag(c64))
	sum := c64 + c64
	code += int(real(complex128(sum))) + 10
	code += int(real(b - a))
	code += int(real(twice(a)))
	intrinsics.syscall(60, uintptr(code))
}

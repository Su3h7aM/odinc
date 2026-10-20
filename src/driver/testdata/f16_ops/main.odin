package main

import "base:intrinsics"

Pair :: struct {
	h: f16,
	n: int,
}

scale :: proc(h: f16, k: f16) -> f16 {
	return h * k
}

pick :: proc(p: ^Pair) -> f16 {
	return p.h
}

main :: proc() {
	a: f16 = 1.5
	b: f16 = 2.25
	code := 0
	s := scale(a, b)
	code += int(f32(s) * 8)
	code += int(a + b)
	code += int(f64(b - a) * 4)
	p := Pair {
		h = 4.0,
		n = 0,
	}
	code += int(pick(&p))
	arr: [3]f16 = {0.5, 1.0, 2.0}
	code += int(arr[2] * 2)
	bits := transmute(u16)a
	code += int((bits >> 10) & 31)
	back := transmute(f16)bits
	if back == a { code += 1 }
	if a < b { code += 2 }
	n := 3
	conv: f16 = f16(n)
	code += int(conv)
	wide := f64(2.5)
	code += int(f16(wide))
	intrinsics.syscall(60, uintptr(code))
}

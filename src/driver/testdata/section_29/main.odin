package main

import "base:intrinsics"

two :: 1.0 + 1.0

Pair :: struct {
	a, b: f64,
}

scale :: proc(p: Pair) -> int {
	return int((p.a + p.b) * 2)
}

main :: proc() {
	x: f64 = 1.5
	y: f64 = 2.5
	z: f32 = 4
	k := int(two)
	value := ((x + y) * f64(z) - f64(k)) / 2
	code := int(value)
	if x >= y { code = 0 }
	switch z {
	case 4:
	case:
		code = 0
	}
	p := Pair{x, y}
	values: [2]f64
	values[0] = p.a
	values[1] = p.b
	intrinsics.syscall(60, uintptr(code + scale(Pair{values[0], values[1]})))
}

package main

import "base:intrinsics"

Info :: struct {
	a: uint,
	b: uint,
	c: int,
}

Nested :: struct {
	p: Info,
	q: bool,
	r: [2]i16,
}

Scaled :: struct {
	f: f32,
	g: f64,
}

info := Info{10, 5, -15}
values := [3]int{1, 2, 3}
nested := Nested{Info{1, 2, 3}, true, {4, 5}}
scaled := Scaled{2, 0.5}

main :: proc() {
	code := int(info.a) + int(info.b) + info.c
	code += values[0] + values[1] + values[2]
	code += nested.p.c + int(nested.r[0]) + int(nested.r[1])
	if nested.q { code += 1 }
	code += int(scaled.f * 4) + int(scaled.g * 10)
	intrinsics.syscall(60, uintptr(code))
}

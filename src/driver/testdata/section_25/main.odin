package main

import "base:intrinsics"

Point :: struct {
	x, y: int,
}

Segment :: struct {
	a, b: Point,
}

main :: proc() {
	s := Segment {
		a = Point{x = 3, y = 4},
		b = Point{1, 2},
	}
	s.b.y = s.a.x + 10
	p := &s.a
	p.y = 20
	c := s
	c.a.x = 100
	intrinsics.syscall(60, uintptr(s.a.x + s.a.y + s.b.x + s.b.y))
}

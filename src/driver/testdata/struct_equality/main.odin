package main

import "base:intrinsics"

Pt :: struct {
	x, y: int,
}

Inner :: struct {
	a: Pt,
	n: int,
}

ArrS :: struct {
	vals: [3]int,
	tag:  string,
}

EnumE :: enum {
	A,
	B,
	C,
}

Mixed :: struct {
	i: int,
	f: f64,
	s: string,
	c: cstring,
	p: ^int,
	e: EnumE,
	b: bool,
}

Uc :: union {
	cstring,
	int,
}

WithUsing :: struct {
	using pt: Pt,
	z:        int,
}

Pad :: struct {
	a: u8,
	b: u64,
	c: u8,
}

generic_eq :: proc(a, b: $T) -> bool where intrinsics.type_is_comparable(T) {
	return a == b
}

main :: proc() {
	code := 0
	p1 := Pt{1, 2}
	p2 := Pt{1, 2}
	p3 := Pt{1, 3}
	if p1 == p2 {
		code += 1
	}
	if p1 != p3 && !(p1 == p3) {
		code += 2
	}
	n1 := Inner{Pt{1, 2}, 5}
	n2 := Inner{Pt{1, 2}, 5}
	n3 := Inner{Pt{1, 2}, 6}
	if n1 == n2 && n1 != n3 {
		code += 4
	}
	a1 := ArrS{[3]int{1, 2, 3}, "hi"}
	a2 := ArrS{[3]int{1, 2, 3}, "hi"}
	a3 := ArrS{[3]int{1, 2, 4}, "hi"}
	if a1 == a2 && a1 != a3 {
		code += 8
	}
	x := 42
	y := 42
	m1 := Mixed{1, 2.5, "s", "c", &x, .B, true}
	m2 := Mixed{1, 2.5, "s", "c", &x, .B, true}
	m3 := Mixed{1, 2.5, "s", "c", &y, .B, true}
	m4 := Mixed{1, 2.5, "s", "c", &x, .C, true}
	m5 := Mixed{1, 2.5, "s", "other", &x, .B, true}
	u1: Uc = cstring("hi")
	u2: Uc = cstring("hi")
	u3: Uc = int(1)
	if m1 == m2 && m1 != m3 && m1 != m4 && m1 != m5 && u1 == u2 && u1 != u3 {
		code += 16
	}
	w1 := WithUsing{Pt{1, 2}, 3}
	w2 := WithUsing{Pt{1, 2}, 3}
	w3 := WithUsing{Pt{1, 2}, 4}
	if w1 == w2 && w1 != w3 {
		code += 32
	}
	if generic_eq(p1, p2) && !generic_eq(p1, p3) {
		code += 64
	}
	q1 := Pad{1, 2, 3}
	q2 := Pad{1, 2, 3}
	(^u8)(uintptr(&q2) + 1)^ = 0xff
	if q1 != q2 {
		code += 128
	}
	intrinsics.syscall(60, uintptr(code))
}

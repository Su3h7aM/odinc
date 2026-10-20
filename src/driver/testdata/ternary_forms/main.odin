package main

import "base:intrinsics"

P :: struct {
	a, b: int,
}

sink :: proc(text: string) -> int {
	return len(text)
}

main :: proc() {
	code := 0
	b := true
	text := b ? "true" : "false"
	if len(text) == 4 { code += 1 }
	off := false
	alt := "true" if off else "false"
	if len(alt) == 5 { code += 2 }
	if sink(b ? "true" : "false") == 4 { code += 4 }
	c := true
	value := c ? 1 : 2
	if value == 1 { code += 8 }
	d := false
	choice := 1 if d else 2
	if choice == 2 { code += 16 }
	c1 := false
	c2 := true
	nested := c1 ? 1 : (c2 ? 20 : 30)
	if nested == 20 { code += 32 }
	p := b ? P{1, 2} : P{3, 4}
	if p.a + p.b * 10 == 21 { code += 64 }
	e := false
	a := []int{1, 2}
	cs := []int{3, 4, 5}
	s := e ? a : cs
	if len(s) * 10 + s[0] == 33 { code += 128 }
	intrinsics.syscall(60, uintptr(code))
}

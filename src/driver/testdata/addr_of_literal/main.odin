package main

import "base:intrinsics"

Point :: struct {
	x, y: int,
}

bump :: proc(p: ^Point) -> int {
	p.x += 10
	return p.x
}

fill :: proc(a: ^[3]int) -> int {
	(a^)[1] = 20
	return (a^)[1]
}

grow :: proc(s: ^[]int) -> int {
	(s^)[0] = 30
	return (s^)[0]
}

main :: proc() {
	p := &Point{x = 1, y = 2}
	p.y = 5
	code := p.x + p.y
	code += bump(&Point{x = 3})
	a := &[3]int{1, 2, 3}
	(a^)[0] = 7
	code += (a^)[0]
	code += fill(&[3]int{0, 0, 0})
	s := &[]int{4, 5}
	(s^)[1] = 6
	code += (s^)[1]
	code += grow(&[]int{1})
	intrinsics.syscall(60, uintptr(code))
}

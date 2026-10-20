package main

import "base:intrinsics"

main :: proc() {
	a: [3]int = {1, 2, 3}
	pa := &a
	pa[1] = 5
	sa := pa[0:2]

	s := []int{4, 5, 6}
	ps := &s
	ps[2] = 7
	ss := ps[1:]

	d := make([dynamic]int, 3)
	pd := &d
	pd[0] = 8
	sd := pd[1:]

	str := "xyz"
	pstr := &str

	code := pa[1] + len(sa) + ps[2] + len(ss) + pd[0] + len(sd) + int(pstr[1])
	intrinsics.syscall(60, uintptr(code))
}

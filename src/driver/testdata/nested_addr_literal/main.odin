package main

import "base:intrinsics"

Bar :: struct {
	n: int,
}

R :: struct {
	p: ^Bar,
}

P_global := &Bar{n = 41}
R_global := R {
	p = &Bar{n = 7},
}
sink: int

clobber :: proc(depth: int) {
	buf: [256]int
	for i in 0 ..< 256 { buf[i] = 0x7e7e7e7e }
	for i in 0 ..< 256 { sink += buf[i] }
	if depth > 0 { clobber(depth - 1) }
}

code: int

@(init)
setup :: proc "contextless" () {
	if P_global.n != 41 { code += 1 }
	if R_global.p.n != 7 { code += 2 }
}

main :: proc() {
	clobber(8)
	if P_global.n != 41 { code += 4 }
	if R_global.p.n != 7 { code += 8 }
	P_global.n = 100
	R_global.p.n = 200
	if P_global.n != 100 { code += 16 }
	if R_global.p.n != 200 { code += 32 }
}

@(fini)
cleanup :: proc "contextless" () {
	if P_global.n != 100 { code += 64 }
	if R_global.p.n != 200 { code += 128 }
	intrinsics.syscall(60, uintptr(code))
}

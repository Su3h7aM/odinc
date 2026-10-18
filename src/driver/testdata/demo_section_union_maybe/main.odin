package main

import "base:intrinsics"

main :: proc() {
	i: Maybe(u8)
	p: Maybe(^u8)
	#assert(size_of(i) == size_of(u8) + size_of(u8))
	#assert(size_of(p) == size_of(^u8))
	i = u8(123)
	x := i.?
	y, y_ok := p.?
	p = &x
	z, z_ok := p.?
	code := int(x) + int(z^)
	if z_ok { code += 1 }
	if !y_ok { code += 1 }
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"

Foo :: bit_field u16 {
	x: i32  | 3,
	y: u16  | 5,
	z: u8   | 4,
	w: bool | 1,
}

main :: proc() {
	v := Foo{}
	v.x = 3
	v.y = 17
	v.z = 9
	v.w = true
	code := int(v.x) + int(v.y) + int(v.z)
	if v.w { code += 1 }
	intrinsics.syscall(60, uintptr(code))
}

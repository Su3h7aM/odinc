package main

import "base:intrinsics"

Vector3 :: struct {
	x: i8,
	y: i16,
	z: f32,
}

main :: proc() {
	v: #soa[3]Vector3
	v[0].x = 1
	v[0].y = 4
	v[0].z = 9
	v[1].x = 2
	v[1].y = 3
	v[1].z = 4
	s: #soa[]Vector3 = v[:]
	code := int(v[0].x) + int(v[0].y) + int(v[1].x) + int(v.z[0]) + len(s)
	intrinsics.syscall(60, uintptr(code))
}

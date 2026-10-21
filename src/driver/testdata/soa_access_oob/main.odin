package main

import "base:intrinsics"

Vec :: struct {
	x, y, z: f32,
}

main :: proc() {
	v: #soa[2]Vec
	v[0].x = 1
	i := 5
	v[i].x = 2
	intrinsics.syscall(60, 0)
}

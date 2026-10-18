package main

import "base:intrinsics"

Point :: struct {
	x, y: i32,
}
Points :: map[Point]int
Names :: map[string]int

main :: proc "contextless" () {
	code := 0
	points := intrinsics.type_map_info(Points)
	a := Point{1, 2}
	b := Point{1, 2}
	c := Point{3, 4}
	if points.key_equal(&a, &b) { code += 1 }
	if !points.key_equal(&a, &c) { code += 2 }
	if points.key_hasher(&a, 7) == points.key_hasher(&b, 7) { code += 4 }
	names := intrinsics.type_map_info(Names)
	gamma := "gamma"
	same := "gamma"
	prefix := "gamm"
	if names.key_equal(&gamma, &same) { code += 8 }
	if !names.key_equal(&gamma, &prefix) { code += 16 }
	if names.key_hasher(&gamma, 7) == names.key_hasher(&same, 7) { code += 32 }
	intrinsics.syscall(60, uintptr(code))
}

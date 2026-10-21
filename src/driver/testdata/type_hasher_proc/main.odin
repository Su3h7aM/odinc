package main

import "base:intrinsics"

Pt :: struct {
	a, b: int,
}
Color :: enum {
	Red,
	Green,
	Blue,
}
Points :: map[Pt]int

// Expected values are the official compiler's type_hasher_proc results (ODIN_ROOT set to its tree, Linux x64).
main :: proc() {
	code := 0
	pt := Pt{1, 2}
	if intrinsics.type_hasher_proc(Pt)(&pt, 0) == 5287849356455185139 { code += 1 }
	arr := [3]int{1, 2, 3}
	if intrinsics.type_hasher_proc([3]int)(&arr, 0) == 6700018986430517539 { code += 2 }
	color := Color.Green
	if intrinsics.type_hasher_proc(Color)(&color, 0) == 2793107945503074095 { code += 4 }
	text := "hi"
	if intrinsics.type_hasher_proc(string)(&text, 0) == 8300543724848622112 { code += 8 }
	if intrinsics.type_hasher_proc(string)(&text, 12345) == 2996082488436527704 { code += 16 }
	points := intrinsics.type_map_info(Points)
	if points.key_hasher(&pt, 0) == intrinsics.type_hasher_proc(Pt)(&pt, 0) { code += 32 }
	intrinsics.syscall(60, uintptr(code))
}

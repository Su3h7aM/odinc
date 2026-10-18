package main

import "base:intrinsics"

simple_sanity_check :: proc(x: [2]int) -> int where len(x) > 1,
	type_of(x) == [2]int {
	return x[0] + x[1]
}

cross_2d :: proc(a, b: $T/[2]$E) -> E where intrinsics.type_is_numeric(E) {
	return a.x * b.y - a.y * b.x
}

cross_3d :: proc(a, b: $T/[3]$E) -> T where intrinsics.type_is_numeric(E) {
	x := a.y * b.z - a.z * b.y
	y := a.z * b.x - a.x * b.z
	z := a.x * b.y - a.y * b.x
	return T{x, y, z}
}

foo :: proc(x: [$N]int) -> bool where N > 2 {
	return true
}

bar :: proc(x: [$N]int) -> bool where 0 < N,
	N <= 2 {
	return false
}

baz :: proc {
	foo,
	bar,
}

main :: proc() {
	code := simple_sanity_check([2]int{1, 2})
	code += cross_2d([2]int{5, -3}, [2]int{1, 2})
	x := [3]f32{1, 4, 9}
	y := [3]f32{-5, 0, 3}
	code += int(cross_3d(x, y).z)
	if baz([3]int{1, 2, 3}) { code += 1 }
	if !baz([2]int{4, 9}) { code += 1 }
	intrinsics.syscall(60, uintptr(code))
}

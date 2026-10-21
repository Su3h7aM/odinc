package main

import "core:fmt"

Vector3 :: distinct [3]f32

main :: proc() {
	a := [3]f32{1, 2, 3}
	b := swizzle(a, 2, 1, 0)
	fmt.println(b)
	c := swizzle(a, 0, 0)
	fmt.println(c)
	v := Vector3{4, 5, 6}
	w := swizzle(v, 2, 1, 0)
	fmt.println(w)
}

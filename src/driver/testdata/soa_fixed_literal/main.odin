package main

import "core:fmt"

V :: struct {
	a: i32,
	b: f64,
	c: f32,
}

g := #soa[3]V{{a = 1, b = 1.0, c = 1.0}, {a = 2, b = 2.0, c = 1.0}, {a = 3, b = 3.0, c = 1.0}}

main :: proc() {
	fmt.println(g[0], g[1], g[2])
	local := #soa[3]V{{a = 1, b = 1.0, c = 1.0}, {a = 2, b = 2.0, c = 1.0}, {a = 3, b = 3.0, c = 1.0}}
	fmt.println(local[0], local[1], local[2])
	sparse := #soa[4]V {
		0 ..= 1 = {a = 7, b = 7.0, c = 7.0},
		3 = {a = 9, b = 9.0, c = 9.0},
	}
	fmt.println(sparse[0], sparse[1], sparse[2], sparse[3])
}

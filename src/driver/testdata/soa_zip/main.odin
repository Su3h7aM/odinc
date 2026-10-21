package main

import "core:fmt"

S :: struct {
	a: i32,
	b: f32,
}

main :: proc() {
	x := []i32{1, 3, 9}
	y := []f32{2, 4, 16}
	z := []b32{true, false, true}
	s := soa_zip(a = x, b = y, c = z)
	for v, i in s {
		fmt.println(i, v.a, v.b, v.c)
	}
	a, b, c := soa_unzip(s)
	fmt.println(a, b, c)
	x[0] = 99
	fmt.println(s.a[0], s.b[0], s.c[0])
	fmt.println(len(s))
	t := soa_zip(a = x, b = y[:1])
	fmt.println(len(t))
	fmt.println(t.a[0], t.b[0])
	u := soa_zip(x, y)
	fmt.println(u._0[2], u._1[2])
	p, q := soa_unzip(u)
	fmt.println(p, q)
	w: #soa[]S = soa_zip(a = x, b = y)
	fmt.println(w.a[1], w.b[1])
}

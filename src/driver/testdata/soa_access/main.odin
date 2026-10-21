package main

import "base:runtime"
import "core:fmt"

Vec :: struct {
	x, y, z: f32,
}
Dyn :: #soa[dynamic]Vec

// Layout-identical stand-in for a dynamic #soa until make/append exist:
// three field pointers, the hidden length and capacity, and the allocator.
Mirror :: struct {
	x, y, z:   [^]f32,
	len, cap:  int,
	allocator: runtime.Allocator,
}

main :: proc() {
	v: #soa[4]Vec
	for i in 0 ..< 4 {
		v[i] = Vec{f32(i * 10 + 1), f32(i * 10 + 2), f32(i * 10 + 3)}
	}
	v[1].x = 100
	fmt.println(len(v))
	for i in 0 ..< 4 {
		fmt.println(v[i].x, v[i].y, v[i].z)
		fmt.println(v.x[i], v.y[i], v.z[i])
	}
	w := v[2]
	fmt.println(w.x, w.y, w.z)
	fmt.println(&v[0].x == &v.x[0])
	s := v[1:3]
	fmt.println(len(s))
	fmt.println(s[0].x, s[1].z)
	sum := f32(0)
	for e, i in s {
		sum += e.x + e.y + e.z + f32(i)
	}
	fmt.println(int(sum))

	a: #soa[4][2]f32
	for i in 0 ..< 4 {
		a[i] = {f32(i + 1), f32(i + 10)}
	}
	a[0].x = 50
	a.y[3] = 60
	for i in 0 ..< 4 {
		fmt.println(a[i].x, a[i].y)
	}
	j := 1
	fmt.println(a[2][j])
	a[3][0] = 70
	fmt.println(a[3])

	bx, by, bz: [4]f32
	m := Mirror{&bx[0], &by[0], &bz[0], 4, 4, {}}
	d := transmute(Dyn)m
	for i in 0 ..< 4 {
		d[i] = Vec{f32(i + 1), f32(i + 2), f32(i + 3)}
	}
	fmt.println(len(d), cap(d))
	t := d[1:3]
	fmt.println(len(t), t[0].x, t[1].z)
	total := 0
	for e, i in d {
		total += int(e.x + e.y + e.z) + i
	}
	fmt.println(total)
}

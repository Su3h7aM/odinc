#+feature using-stmt
package main

import "base:intrinsics"

Point :: struct {
	x, y: int,
}
Large :: struct {
	a, b, c, d, e: int,
}
Embedded :: struct {
	using inner: ^Point,
}

read_value :: proc(using value: Point) -> int { return x + y + value.x }
read_large :: proc(using value: Large) -> int { return a + b + c + d + e + value.e }
read_default :: proc(using value := Point{4, 9}) -> int { return x + y }

mutate_pointer :: proc "contextless" (using value: ^Point) -> int {
	x += y
	address := &x
	address^ += 1
	return value.x
}

mutate_pointee :: proc(using value: Embedded) -> int {
	inner.x += inner.y
	return x + value.inner.x
}

shadow_root_and_alias :: proc(using original: Point) -> int {
	original := Point{40, 50}
	total := original.x + x
	{ x := 7; total += x }
	return total
}

shadow_ordinary_parameter :: proc(value: Point) -> int {
	value := Point{9, 8}
	return value.x
}

main :: proc() {
	code := 0
	point := Point{2, 3}
	if read_value(point) == 7 && point.x == 2 { code += 1 }
	if read_large(Large{1, 2, 3, 4, 5}) == 20 { code += 2 }
	if read_default() == 13 && read_default(Point{2, 5}) == 7 { code += 4 }
	if mutate_pointer(&point) == 6 && point.x == 6 { code += 8 }
	pointee := Point{2, 3}
	if mutate_pointee(Embedded{&pointee}) == 10 && pointee.x == 5 { code += 16 }
	if shadow_root_and_alias(Point{2, 3}) == 49 { code += 32 }
	if shadow_ordinary_parameter(point) == 9 && point.x == 6 { code += 64 }
	intrinsics.syscall(60, uintptr(code))
}

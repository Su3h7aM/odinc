#+feature using-stmt
package main

import "base:intrinsics"
import namespace "namespace"

Point :: struct {
	x, y: int,
}
Outer :: struct {
	position: Point,
}
Kind :: enum {
	First  = 3,
	Second = 7,
}
WithPoint :: struct {
	using position: Point,
}
outer: Outer
calls: int

make_outer :: proc() -> Outer { return Outer{Point{7, 8}} }

check_nested_bindings :: proc() -> bool {
	Blank :: struct {
		_: int,
		_: int,
		x: int,
	}
	Pointer :: struct {
		using embedded: ^Point,
	}
	Nested :: struct {
		using inner: WithPoint,
	}
	Recursive :: struct {
		using next: ^Recursive,
	}
	{
		value := Blank{1, 2, 7}
		using value
		if x != 7 { return false }
	}
	{
		target := Point{2, 3}
		replacement := Point{7, 8}
		value := Pointer{&target}
		using value
		x += y
		address := &x
		address^ += 1
		read := x
		embedded = &replacement
		x += 2
		if target.x != 6 || read != 6 || replacement.x != 9 || y != 8 { return false }
	}
	{
		value := Nested{WithPoint{Point{3, 4}}}
		using value
		x += y
		if value.inner.position.x != 7 { return false }
	}
	{
		value: Recursive
		_ = value
	}
	return true
}

get :: proc() -> ^Outer {
	calls += 1
	marker: string = "!"
	intrinsics.syscall(1, 1, uintptr(raw_data(marker)), 1)
	return &outer
}

main :: proc() {
	code := 0
	point := Point{2, 5}
	{
		using point
		x += y
		x_address := &x
		x_address^ += 1
		if point.x == 8 { code += 1 }
	}
	x := 99
	{
		using point
		x = 10
		{ x := 12; if x == 12 { code += 2 } }
	}
	if x == 99 && point.x == 10 { code += 4 }
	{
		first := Point{1, 2}
		second := Point{3, 4}
		pointer := &first
		using pointer
		pointer = &second
		x = 13
		if first.x == 1 && second.x == 13 { code += 8 }
	}
	{
		using get().position
	}
	{
		using get().position
		if calls != 0 { intrinsics.syscall(60, 1) }
		x = 5
		read := x
		x += 2
		address := &x
		address^ += 1
		if calls == 4 && read == 5 && outer.position.x == 8 { code += 16 }
	}
	{
		using namespace
		using Kind
		using Kind
		if answer + int(First) + int(Second) == 27 { code += 32 }
	}
	{
		using make_outer().position
		if x == 7 && y == 8 { code += 64 }
	}
	{
		value := WithPoint{Point{3, 4}}
		using value
		x += 9
		if value.position.x == 12 && y == 4 && check_nested_bindings() { code += 128 }
	}
	intrinsics.syscall(60, uintptr(code))
}

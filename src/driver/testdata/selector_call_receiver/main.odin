package main

import "base:intrinsics"

Impl :: struct {
	data:    rawptr,
	marshal: proc "contextless" (data: rawptr, n: int) -> int,
}

marshal_data :: proc "contextless" (data: rawptr, n: int) -> int {
	if data == nil { return -1 }
	return n
}

Value :: struct {
	id:   int,
	show: proc "contextless" (v: Value, n: int) -> int,
}

show_value :: proc "contextless" (v: Value, n: int) -> int { return v.id * 10 + n }

Pointed :: struct {
	id:   int,
	show: proc "contextless" (p: ^Pointed, n: int) -> int,
}

show_pointed :: proc "contextless" (p: ^Pointed, n: int) -> int { return p.id * 10 + n }

Inner :: struct {
	id:   int,
	show: proc "contextless" (p: ^Inner, n: int) -> int,
}

show_inner :: proc "contextless" (p: ^Inner, n: int) -> int { return p.id * 100 + n }

Outer :: struct {
	pad:         int,
	using inner: Inner,
}

Defaulted :: struct {
	id:   int,
	show: proc "contextless" (d: ^Defaulted, scale: int, offset := 1) -> int,
}

show_defaulted :: proc "contextless" (d: ^Defaulted, scale: int, offset := 1) -> int {
	return d.id * scale + offset
}

Boxed :: struct {
	id:   int,
	show: proc "contextless" (d: any, n: int) -> int,
}

show_boxed :: proc "contextless" (d: any, n: int) -> int {
	boxed, ok := d.(^Boxed)
	if !ok { return -1 }
	return boxed.id * 10 + n
}

calls: int

make_pointed :: proc "contextless" (p: ^Pointed) -> ^Pointed {
	calls += 1
	return p
}

make_boxed :: proc "contextless" (b: ^Boxed) -> ^Boxed {
	calls += 1
	return b
}

main :: proc() {
	code := 0

	impl := Impl {
		marshal = marshal_data,
	}
	pimpl := &impl
	if impl->marshal(2) == 2 && pimpl->marshal(3) == 3 { code += 1 }

	value := Value {
		id   = 4,
		show = show_value,
	}
	pvalue := &value
	if value->show(5) == 45 && pvalue->show(6) == 46 { code += 2 }

	pointed := Pointed {
		id   = 3,
		show = show_pointed,
	}
	if pointed->show(7) == 37 { code += 4 }

	outer := Outer {
		pad = 9,
		inner = Inner{id = 2, show = show_inner},
	}
	if outer->show(8) == 208 { code += 8 }

	defaulted := Defaulted {
		id   = 6,
		show = show_defaulted,
	}
	if defaulted->show(scale = 2) == 13 && defaulted->show(3, offset = 0) == 18 { code += 16 }

	calls = 0
	if make_pointed(&pointed)->show(1) == 31 && calls == 1 { code += 32 }

	boxed := Boxed {
		id   = 5,
		show = show_boxed,
	}
	calls = 0
	if make_boxed(&boxed)->show(2) == 52 && calls == 1 { code += 64 }

	intrinsics.syscall(60, uintptr(code))
}

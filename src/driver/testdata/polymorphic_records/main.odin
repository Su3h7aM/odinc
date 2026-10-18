package main

import "base:intrinsics"

Foo :: struct(T: typeid) {
	value: T,
}
Small_Array :: struct($N: int, $T: typeid) where N >= 0 && T == int {
	data: [N]T,
	len:  int,
}
Nested :: struct($T: typeid) {
	value: Foo(T),
	next:  ^Nested(T),
}
Choice :: union($T: typeid) {
	T,
	^T,
}
Handle :: distinct Foo(int)
Map_Cell :: struct($T: typeid) #align (64) {
	data: [64 / size_of(T) when 0 < size_of(T) && size_of(T) < 64 else 1]T,
}
Fixed :: struct($Capacity: uint, $T: typeid) {
	data: [Capacity]T,
	len:  int,
}

read :: proc "contextless" (value: ^Foo($T)) -> T { return value.value }
make_foo :: proc "contextless" (value: $T) -> Foo(T) { return Foo(T){value = value} }
count :: proc "contextless" (value: ^Small_Array($N, $T)) -> int { return N + value.len }

main :: proc() {
	result := 0
	foo := make_foo(7)
	if read(&foo) == 7 { result += 1 }
	first: Small_Array(3, int)
	first.data[2], first.len = 11, 2
	same: Small_Array(1 + 2, int) = first
	if same.data[2] == 11 && count(&same) == 5 { result += 2 }
	nested := Nested(int) {
		value = Foo(int){value = 13},
	}
	if nested.value.value == 13 { result += 4 }
	chosen := 17
	choice: Choice(int) = chosen
	switch value in choice {
	case int:
		if value == 17 { result += 8 }
	case ^int:
	}
	handle := Handle {
		value = 19,
	}
	if handle.value == 19 { result += 16 }
	if size_of(Map_Cell(int)) == 64 && align_of(Map_Cell(int)) == 64 { result += 32 }
	fixed: Fixed(4, int)
	fixed.data[3], fixed.len = 29, 4
	if fixed.data[3] == 29 && fixed.len == 4 { result += 64 }
	intrinsics.syscall(60, uintptr(result))
}

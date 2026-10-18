package main

import "base:intrinsics"

My_Iterator :: struct {
	index: int,
	data:  []i32,
}

make_my_iterator :: proc(data: []i32) -> My_Iterator {
	return My_Iterator{data = data}
}

my_iterator :: proc(it: ^My_Iterator) -> (val: i32, idx: int, cond: bool) {
	if cond = it.index < len(it.data); cond {
		val = it.data[it.index]
		idx = it.index
		it.index += 1
	}
	return
}

main :: proc() {
	data := [6]i32{0, 1, 4, 9, 16, 25}
	code := 0
	{
		it := make_my_iterator(data[:])
		for val in my_iterator(&it) {
			code += int(val)
		}
	}
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"

main :: proc() {
	x: int
	any_zero: any
	any_set: any = any{&x, typeid_of(int)}
	any_nil_data := any{nil, typeid_of(int)}
	any_nil_id := any{&x, nil}
	map_zero: map[int]int
	dynamic_zero: [dynamic]int
	slice_zero: []int
	code := 0
	if any_zero == nil {
		code += 1
	}
	if any_set != nil {
		code += 2
	}
	if any_nil_data == nil {
		code += 4
	}
	if any_nil_id == nil {
		code += 8
	}
	if any_set == nil {
		code += 16
	}
	if map_zero == nil {
		code += 32
	}
	if dynamic_zero == nil {
		code += 64
	}
	if slice_zero == nil {
		code += 128
	}
	intrinsics.syscall(60, uintptr(code))
}

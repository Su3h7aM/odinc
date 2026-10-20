package main

import "base:intrinsics"
import "base:runtime"

optional_calls: int

optional_allocator_value :: proc(value: int) -> (int, runtime.Allocator_Error) #optional_allocator_error {
	optional_calls += 1
	return value, .None
}

main :: proc() {
	single := optional_allocator_value(7)
	optional_allocator_value(2)
	multiple, allocator_error := optional_allocator_value(11)
	values: map[int]int
	value_ptr := map_insert(&values, 3, 42)
	code := 42
	if single != 7 || multiple != 11 || allocator_error != .None || optional_calls != 3 { code += 1 }
	if value_ptr == nil || value_ptr^ != 42 || values[3] != 42 { code += 2 }
	intrinsics.syscall(60, uintptr(code))
}

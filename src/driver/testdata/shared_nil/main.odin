package main

import "core:sys/linux"

Error :: enum u8 {
	None,
	Failed,
}
Value :: union #shared_nil {
	Error,
	^int,
	[]int,
}

result :: proc(error: Error) -> (string, Value) {
	return "ok", error
}

pointer_value :: proc(pointer: ^int) -> Value {
	return pointer
}

slice_value :: proc(slice: []int) -> Value {
	return slice
}

main :: proc() {
	text, error := result(.None)
	if text != "ok" || error != nil { linux.exit_group(1) }
	_, error = result(.Failed)
	if error == nil || error.(Error) != .Failed { linux.exit_group(2) }
	if pointer_value(nil) != nil { linux.exit_group(3) }
	number := 7
	if pointer_value(&number) == nil { linux.exit_group(4) }
	if slice_value(nil) != nil { linux.exit_group(5) }
	array := [1]int{9}
	value := slice_value(array[:])
	if value == nil || value.([]int)[0] != 9 { linux.exit_group(6) }
	linux.exit_group(42)
}

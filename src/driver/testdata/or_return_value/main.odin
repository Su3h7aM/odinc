package sample

import "base:intrinsics"

trace: u8
payload: u8

Error :: enum u8 {
	None,
	Bad,
	Worse,
}

direct :: proc "contextless" (e: Error) -> Error {
	e or_return
	return .None
}

named :: proc "contextless" (e: Error) -> (value: u8, err: Error) {
	defer trace += 1
	value = 3
	e or_return
	trace += 2
	return
}

stored :: proc "contextless" (e: Error) -> Error {
	saved := e
	saved or_return
	return .None
}

bool_value :: proc "contextless" (flag: bool) -> bool {
	flag or_return
	return true
}

pointer_value :: proc "contextless" (value: ^u8) -> ^u8 {
	value or_return
	return nil
}

enum_param :: proc "contextless" (a: int, e: Error) -> (value: int, err: Error) {
	e or_return
	return a, .None
}

main :: proc() {
	if int(direct(.None)) != 0 || int(direct(.Bad)) != 1 { intrinsics.syscall(60, uintptr(1)) }
	if int(stored(.None)) != 0 || int(stored(.Worse)) != 2 { intrinsics.syscall(60, uintptr(2)) }
	if bool_value(true) != true || bool_value(false) != false { intrinsics.syscall(60, uintptr(3)) }
	if pointer_value(nil) != nil || pointer_value(&payload) != &payload { intrinsics.syscall(60, uintptr(4)) }
	value, err := named(.None)
	if value != 3 || int(err) != 0 || trace != 3 { intrinsics.syscall(60, uintptr(5)) }
	value, err = named(.Bad)
	if value != 3 || int(err) != 1 || trace != 4 { intrinsics.syscall(60, uintptr(6)) }
	first, first_err := enum_param(5, .None)
	if first != 5 || int(first_err) != 0 { intrinsics.syscall(60, uintptr(7)) }
	second, second_err := enum_param(6, .Worse)
	if second != 0 || int(second_err) != 2 { intrinsics.syscall(60, uintptr(8)) }
	intrinsics.syscall(60, uintptr(0))
}

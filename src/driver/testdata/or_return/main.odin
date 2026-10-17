package sample

import "base:intrinsics"

trace: u8
pointer_trace: u8
payload: u8

bool_pair :: proc "contextless" (ok: bool) -> (u8, bool) {
	return 7, ok
}

bool_value_pair :: proc "contextless" (ok: bool) -> (bool, bool) {
	return true, ok
}

pointer_pair :: proc "contextless" (ok: bool) -> (^u8, ^u8) {
	if ok {
		return nil, nil
	}
	return &payload, &payload
}

pointer_return :: proc "contextless" (ok: bool) -> ^u8 {
	value := pointer_pair(ok) or_return
	pointer_trace += 1
	return value
}

bool_return :: proc "contextless" (ok: bool) -> bool {
	return bool_value_pair(ok) or_return
}

named_return :: proc "contextless" (ok: bool) -> (value: u8, status: bool) {
	defer trace += 10
	value = 3
	status = true
	_ = bool_pair(ok) or_return
	trace += 1
	return
}

status_statement :: proc "contextless" (ok: bool) -> bool {
	bool_status(ok) or_return
	return true
}

bool_status :: proc "contextless" (ok: bool) -> bool {
	return ok
}

main :: proc "contextless" () {
	failed_value, failed_status := named_return(false)
	if failed_value != 3 || failed_status || trace != 10 { intrinsics.syscall(60, uintptr(1)) }
	success_value, success_status := named_return(true)
	if success_value != 3 || !success_status || trace != 21 { intrinsics.syscall(60, uintptr(2)) }
	if status_statement(false) != false || status_statement(true) != true { intrinsics.syscall(60, uintptr(3)) }
	if bool_return(true) != true || bool_return(false) != false { intrinsics.syscall(60, uintptr(4)) }
	if pointer_return(true) != nil || pointer_return(false) != &payload || pointer_trace != 1 { intrinsics.syscall(60, uintptr(5)) }
	intrinsics.syscall(60, uintptr(0))
}

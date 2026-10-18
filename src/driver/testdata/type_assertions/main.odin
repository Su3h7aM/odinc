package main

import "base:intrinsics"

Value :: union {
	i64,
	bool,
}

main :: proc() {
	union_value: Value = i64(23)
	union_single := union_value.(i64)
	union_success, union_success_ok := union_value.(i64)
	union_failure, union_failure_ok := union_value.(bool)
	union_pointer := &union_value
	pointer_single := union_pointer.(i64)
	pointer_failure, pointer_failure_ok := union_pointer.(bool)

	any_value: any = i64(41)
	any_single := any_value.(i64)
	any_success, any_success_ok := any_value.(i64)
	any_failure, any_failure_ok := any_value.(bool)

	code := 0
	if union_single == 23 { code += 1 }
	if union_success == 23 && union_success_ok { code += 2 }
	if union_failure == false && !union_failure_ok { code += 4 }
	if pointer_single == 23 { code += 64 }
	if pointer_failure == false && !pointer_failure_ok { code += 128 }
	if any_single == 41 { code += 8 }
	if any_success == 41 && any_success_ok { code += 16 }
	if any_failure == false && !any_failure_ok { code += 32 }
	intrinsics.syscall(60, uintptr(code))
}

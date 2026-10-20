package sample

import "base:intrinsics"

marker: u8
calls: int
bool_calls: int
pointer_calls: int
continued: int
body_value: int
inner_defers: int
outer_defers: int

pair :: proc "contextless" (ok: bool) -> (int, bool) {
	calls += 1
	return 5, ok
}

boolean_status :: proc "contextless" (ok: bool) -> bool {
	bool_calls += 1
	return ok
}

pointer_pair :: proc "contextless" (ok: bool) -> (int, ^u8) {
	pointer_calls += 1
	if ok { return 9, nil }
	return 0, &marker
}

main :: proc() {
	index := 0
	for ; index < 3; index += 1 {
		value := (pair(index == 0)) or_continue
		body_value += value
	}
	if calls != 3 || body_value != 5 || index != 3 { intrinsics.syscall(60, 11) }

	index = 0
	fn := pair
	for ; index < 2; index += 1 {
		fn(index == 0) or_continue
		continued += 100
	}
	if calls != 5 || continued != 100 || index != 2 { intrinsics.syscall(60, 12) }

	index = 0
	for ; index < 2; index += 1 {
		value := pointer_pair(index == 0) or_continue
		body_value += value
	}
	if pointer_calls != 2 || body_value != 14 || index != 2 { intrinsics.syscall(60, 13) }

	index = 0
	for ; index < 2; index += 1 {
		boolean_status(index == 0) or_continue
		continued += 1
	}
	if bool_calls != 2 || continued != 101 || index != 2 { intrinsics.syscall(60, 14) }

	index = 0
	outer: for ; index < 2; index += 1 {
		defer outer_defers += 1
		for {
			defer inner_defers += 1
			pair(false) or_continue outer
		}
	}
	if calls != 7 || outer_defers != 2 || inner_defers != 2 || index != 2 { intrinsics.syscall(60, 15) }
	intrinsics.syscall(60, 0)
}

package sample

import "base:intrinsics"

calls: u8
body_runs: int
defer_runs: u8
outer_runs: u8
status_runs: u8
marker: u8

status :: proc "contextless" (ok: bool) -> (u8, bool) {
	calls += 1
	return 7, ok
}

status_only :: proc "contextless" (ok: bool) -> bool {
	calls += 1
	return ok
}

pointer_status :: proc "contextless" (ok: bool) -> (u8, ^u8) {
	if ok { return 9, nil }
	return 0, &marker
}

main :: proc() {
	value: u8 = 0
	for {
		value = status(true) or_break
		body_runs += 1
		break
	}
	if value != 7 || calls != 1 || body_runs != 1 { intrinsics.syscall(60, 1) }
	pointer_value: u8
	for {
		pointer_value = pointer_status(true) or_break
		break
	}
	if pointer_value != 9 { intrinsics.syscall(60, 4) }
	for {
		pointer_status(false) or_break
		body_runs += 800
	}
	if body_runs != 1 { intrinsics.syscall(60, 5) }

	outer: for {
		defer outer_runs += 1
		for {
			defer defer_runs += 1
			status(false) or_break outer
			body_runs += 100
		}
		body_runs += 200
	}
	if calls != 2 { intrinsics.syscall(60, 2) }
	if body_runs != 1 { intrinsics.syscall(60, 6) }
	if defer_runs != 1 { intrinsics.syscall(60, 7) }
	if outer_runs != 1 { intrinsics.syscall(60, 8) }
	for {
		status_only(true) or_break
		status_runs += 1
		break
	}
	for {
		status_only(false) or_break
		status_runs += 100
	}
	if calls != 4 || body_runs != 1 || status_runs != 1 { intrinsics.syscall(60, 3) }
	intrinsics.syscall(60, 73)
}

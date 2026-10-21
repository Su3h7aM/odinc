package main

import "base:intrinsics"

Record :: struct {
	callback: proc(x := 3) -> int,
}
target :: proc(z := 1) -> int { return z }
get_callback :: proc() -> proc(x := 7) -> int { return target }
formal :: proc(callback: proc(arg := 5) -> int) -> int { return callback() }
pass_through :: proc(callback: proc(arg := 4) -> int) -> proc(res := 6) -> int { return callback }

evaluations: int
callees: int
order: int
returned :: proc() -> proc(first: int, second := 2) -> int {
	evaluations += 1
	return combine
}
combine :: proc(a, b: int) -> int { return 10 * a + b }
next :: proc(value: int) -> int { order = 10 * order + value; return value }
counted :: proc() -> proc(x := 4) -> int {
	callees += 1
	return target
}

main :: proc() {
	a: proc(x := 3) -> int = target
	b: proc(x := 7) -> int = target
	record := Record{target}
	inferred := b
	before := inferred()
	inferred = a
	callbacks := [1]proc(x := 4) -> int{target}
	if record.callback() != 3 || get_callback()() != 7 { intrinsics.syscall(60, 1) }
	if formal(a) != 5 || pass_through(b)() != 6 { intrinsics.syscall(60, 2) }
	if before != 7 || inferred() != 7 || callbacks[0]() != 4 { intrinsics.syscall(60, 3) }
	if b(x = 9) != 9 { intrinsics.syscall(60, 4) }
	if returned()(second = next(2), first = next(1)) != 12 { intrinsics.syscall(60, 5) }
	if evaluations != 1 || order != 21 { intrinsics.syscall(60, 6) }
	if returned()(first = 4) != 42 || evaluations != 2 { intrinsics.syscall(60, 7) }
	if counted()() != 4 || callees != 1 { intrinsics.syscall(60, 8) }
}

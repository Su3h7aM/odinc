package main

import "base:intrinsics"

main :: proc() {
	add_ints :: proc(a, b: int) -> int { return a + b }
	identity :: proc(a: int) -> int { return a }
	pick :: proc {
		add_ints,
		identity,
	}

	small :: proc(x: [$N]int) -> int where N <= 2 { return 1 }
	large :: proc(x: [$N]int) -> int where N > 2 { return 2 }
	size_kind :: proc {
		small,
		large,
	}

	code := pick(1, 2) + pick(4)
	code += size_kind([4]int{1, 2, 3, 4}) + size_kind([2]int{1, 2})
	intrinsics.syscall(60, uintptr(code))
}

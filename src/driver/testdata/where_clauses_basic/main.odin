package main

import "base:intrinsics"

simple :: proc(x: [2]int) -> int where len(x) > 1,
	type_of(x) == [2]int {
	return x[0] + x[1]
}

larger :: proc(x: [$N]int) -> bool where N > 2 {
	return true
}

smaller :: proc(x: [$N]int) -> bool where 0 < N,
	N <= 2 {
	return false
}

select :: proc {
	larger,
	smaller,
}

main :: proc() {
	code := simple([2]int{1, 2})
	if select([3]int{1, 2, 3}) { code += 1 }
	if !select([2]int{1, 2}) { code += 1 }
	intrinsics.syscall(60, uintptr(code))
}

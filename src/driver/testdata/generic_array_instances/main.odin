package main

import "base:intrinsics"

ascending :: proc(values: [$N]int) -> int { return N + values[0] }
descending :: proc(values: [$N]int) -> int { return N + values[0] }
pair :: proc(left: [$N]int, right: [$M]int) -> int { return N * 10 + M + left[0] + right[0] }

main :: proc() {
	three := [3]int{1, 2, 3}
	four := [4]int{1, 2, 3, 4}
	code := 0
	if ascending(three) == 4 && ascending(four) == 5 { code += 1 }
	if descending(four) == 5 && descending(three) == 4 { code += 2 }
	if ascending(three) == 4 && ascending(four) == 5 { code += 4 }
	if pair(three, four) == 36 && pair(four, three) == 45 { code += 8 }
	intrinsics.syscall(60, uintptr(code))
}

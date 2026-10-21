#+feature dynamic-literals
package main

import "base:intrinsics"

xs := [dynamic]int{1, 2, 3}
ys: [dynamic]int = {4, 5}
m := map[string]int {
	"a" = 1,
}
nested := [dynamic][dynamic]int{{1}, {2, 3}}
b := a + 1
a := 41
from_call := make_value()

make_value :: proc "contextless" () -> int { return 9 }

main :: proc() {
	code := 0
	if len(xs) != 3 { code += 1 }
	if xs[0] + xs[1] + xs[2] != 6 { code += 2 }
	if len(ys) != 2 || ys[0] + ys[1] != 9 { code += 4 }
	if len(m) != 1 || m["a"] != 1 { code += 8 }
	if len(nested) != 2 || len(nested[0]) != 1 || len(nested[1]) != 2 { code += 16 }
	if nested[0][0] + nested[1][0] + nested[1][1] != 6 { code += 32 }
	if b != 42 { code += 64 }
	if from_call != 9 { code += 128 }
	intrinsics.syscall(60, uintptr(code))
}

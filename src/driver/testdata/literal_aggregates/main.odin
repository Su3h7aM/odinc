#+feature dynamic-literals
package main

import "base:intrinsics"

main :: proc() {
	code := 0

	d := [dynamic]int{1, 2, 3}
	if len(d) == 3 && cap(d) == 3 { code += 1 }
	if d[0] == 1 && d[1] == 2 && d[2] == 3 { code += 2 }
	append(&d, 4)
	if len(d) == 4 && d[3] == 4 { code += 4 }

	e := [dynamic]int{}
	if len(e) == 0 && cap(e) == 0 { code += 8 }

	m := map[string]int {
		"a" = 1,
		"b" = 2,
	}
	if len(m) == 2 && m["a"] == 1 && m["b"] == 2 { code += 16 }
	if cap(m) == 8 { code += 32 }
	sum := 0
	for k, v in m { sum += len(k) * 100 + v }
	if sum == 203 { code += 64 }

	z := map[string]int{}
	empty_ok := len(z) == 0
	z["x"] = 5
	if empty_ok && len(z) == 1 && z["x"] == 5 { code += 128 }

	delete(d)
	delete(e)
	delete(m)
	delete(z)
	intrinsics.syscall(60, uintptr(code))
}

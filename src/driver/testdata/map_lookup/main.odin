package main

import "base:intrinsics"

main :: proc() {
	code := 0
	integers: map[int]int
	if integers[7] != 0 { code += 1 }
	missing := integers[99]
	if missing != 0 { code += 2 }
	value, ok := integers[7]
	if ok || value != 0 { code += 4 }
	if 7 in integers || 99 in integers { code += 8 }
	fallback := integers[99] or_else 23
	if fallback != 23 { code += 16 }

	strings: map[string]int
	if strings["found"] != 0 { code += 32 }
	if strings["missing"] != 0 { code += 64 }
	intrinsics.syscall(60, uintptr(code))
}

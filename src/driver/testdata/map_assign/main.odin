package main

import "base:intrinsics"

main :: proc() {
	code := 0

	integers: map[int]int
	integers[7] = 19
	if integers[7] != 19 { code += 128 }
	integers[7] = 23
	if integers[7] != 23 { code += 256 }
	integers[1] = 7
	integers[1] += 1
	if integers[1] != 8 { code += 1 }
	integers[2] += 1
	if integers[2] != 1 { code += 2 }
	integers[1] = 9
	if integers[1] != 9 { code += 4 }
	for index in 0 ..< 64 {
		integers[index + 100] = index
	}
	if len(integers) != 67 { code += 8 }
	if integers[1] != 9 || integers[2] != 1 || integers[7] != 23 || integers[100] != 0 || integers[163] != 63 { code += 16 }

	strings: map[string]int
	strings["one"] = 11
	strings["two"] = 12
	strings["one"] += 1
	if strings["one"] != 12 || strings["two"] != 12 { code += 32 }
	strings["one"] = 13
	if len(strings) != 2 || strings["one"] != 13 { code += 64 }

	intrinsics.syscall(60, uintptr(code + 42))
}

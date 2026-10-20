package main

import "base:intrinsics"

main :: proc() {
	code := 0
	empty: map[int]int
	empty_count := 0
	for key, value in empty {
		_ = key
		_ = value
		empty_count += 1
	}
	if cap(empty) != 0 || empty_count != 0 { code += 1 }

	values: map[int]int
	values[1] = 10
	values[2] = 20
	values[3] = 30
	if cap(values) < len(values) { code += 2 }

	count, key_sum, value_sum := 0, 0, 0
	for key, value in values {
		count += 1
		key_sum += key
		if key == 1 { continue }
		value_sum += value
	}
	if count != 3 { code += 4 }
	if key_sum != 6 { code += 8 }
	if value_sum != 50 { code += 16 }

	break_count := 0
	for key in values {
		_ = key
		break_count += 1
		break
	}
	if break_count != 1 { code += 8 }

	for key, &value in values {
		_ = key
		value += 1
	}
	if values[1] != 11 { code += 32 }
	if values[2] != 21 { code += 64 }
	if values[3] != 31 { code += 128 }

	strings: map[string]int
	strings["left"] = 7
	strings["right"] = 9
	string_code := 0
	for key, value in strings {
		if key == "left" { string_code += value } else { string_code += value * 2 }
	}
	if len(strings) != 2 || string_code != 25 { code += 256 }

	intrinsics.syscall(60, uintptr(code + 42))
}

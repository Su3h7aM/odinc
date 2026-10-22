package main

import "base:intrinsics"

rhs :: proc(calls: ^int, value: bool) -> bool {
	calls^ += 1
	return value
}

position :: proc(calls: ^int) -> int {
	calls^ += 1
	return 0
}

main :: proc() {
	code := 42
	calls := 0
	value := false
	value &&= rhs(&calls, true)
	value ||= rhs(&calls, true)
	value ||= rhs(&calls, false)
	value &&= rhs(&calls, false)
	if value || calls != 2 { code = 1 }

	calls = 0
	value = true
	for index in 0 ..< 3 { value &&= rhs(&calls, index != 1) }
	if value || calls != 2 { code = 2 }

	positions := 0
	calls = 0
	values: [1]bool
	values[position(&positions)] ||= rhs(&calls, true)
	values[position(&positions)] &&= rhs(&calls, false)
	if values[0] || positions != 4 || calls != 2 { code = 3 }

	wide: b32
	wide ||= true
	wide &&= false
	if wide { code = 4 }

	intrinsics.syscall(60, uintptr(code))
}

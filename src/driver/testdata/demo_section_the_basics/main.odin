package main

import "base:intrinsics"

main :: proc() {
	code := 0
	values := [3]int{2, 3, 5}
	slice := values[:]
	value := &slice[1]
	if len(slice) == 3 && value^ == 3 { code += 2 }
	{
		defer code += 8
		code += 4
	}
	intrinsics.syscall(60, uintptr(code))
}

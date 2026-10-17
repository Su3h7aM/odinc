package main

import "base:intrinsics"

compute :: proc "contextless" () -> int {
	total := 1
	defer total = total + 10
	{
		defer total = total * 3
		total = total + 2
	}
	if total == 9 {
		return total
	}
	return 0
}

count_breaks :: proc "contextless" () -> int {
	total := 0
	for i := 0; i < 5; i = i + 1 {
		defer total = total + 1
		if i == 2 { break }
	}
	return total
}

main :: proc() {
	first := compute()
	second := count_breaks()
	total := first * 10 + second
	intrinsics.syscall(60, uintptr(total))
}

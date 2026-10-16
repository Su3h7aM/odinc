package main

import "base:intrinsics"

main :: proc() {
	values: [4]int
	values[0] = 3
	values[1] = 4
	values[2] = 7
	values[3] = 1
	total := 0
	p := &total
	p^ = p^ + values[2]
	total += values[0] * 2
	total -= 1
	ok := total > 10 && values[3] == 1
	if ok || total == 0 {
		total += 100
	}
	total /= 2
	#no_bounds_check for i := 0; i < 4; i = i + 1 {
		total += values[i]
	}
	intrinsics.syscall(60, uintptr(total))
}

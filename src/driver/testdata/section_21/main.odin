package main

import "base:intrinsics"

main :: proc() {
	total := 0
	i := 0
	for i < 10 {
		i = i + 1
		if i == 3 {
			continue
		} else if i == 8 {
			break
		} else {
			total = total + i
		}
	}
	outer: for j := 0; j < 3; j = j + 1 {
		for k := 0; k < 3; k = k + 1 {
			total = total + 1
			if k == 1 { break outer }
		}
	}
	when 1 < 2 {
		total = total + 100
	} else {
		total = 0
	}
	intrinsics.syscall(60, uintptr(total))
}

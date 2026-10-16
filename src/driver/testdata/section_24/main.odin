package main

import "base:intrinsics"

main :: proc() {
	total := 0
	for i := 0; i < 5; i = i + 1 {
		switch i {
		case 0:
			total = total + 1
		case 1, 2:
			total = total + 10
		case 3:
			break
		case:
			total = total + 100
		}
	}
	switch {
	case total > 100:
		total = total + 1
	case total > 1000:
		total = 0
	}
	intrinsics.syscall(60, uintptr(total))
}

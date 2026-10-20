package main

import "base:intrinsics"

main :: proc() {
	left := 1 + 2i + 3j + 4k
	right := quaternion(real = 5, imag = 6, jmag = 7, kmag = 8)
	product := left * right
	intrinsics.syscall(60, uintptr(int(real(product)) + 100))
}

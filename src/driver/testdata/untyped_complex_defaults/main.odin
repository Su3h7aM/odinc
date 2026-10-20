package main

import "base:intrinsics"

main :: proc() {
	q := 1 + 2i + 3j + 4k
	r := quaternion(real = 5, imag = 6, jmag = 7, kmag = 8)
	sum := q + r
	difference := q - r
	c := 4i
	#assert(type_of(q) == quaternion256)
	#assert(type_of(c) == complex128)
	code := int(real(sum) + imag(sum) + jmag(sum) + kmag(sum) + imag(c) - real(difference))
	intrinsics.syscall(60, uintptr(code))
}

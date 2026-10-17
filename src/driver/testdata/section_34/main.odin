package main

import "base:intrinsics"

seen: int

bump :: proc "contextless" (value: ^int) {
	value^ += 10
}

pair :: proc "contextless" (x: int) -> (low, high: int) {
	low = x
	high = x * 2
	return
}

explicit :: proc "contextless" () -> (value: int) {
	defer seen = value
	value = 4
	return 5
}

pointer_defer :: proc "contextless" () -> (value: int) {
	defer bump(&value)
	value = 2
	return
}

main :: proc "contextless" () {
	first, second := pair(3)
	third := explicit()
	fourth := pointer_defer()
	intrinsics.syscall(60, uintptr(first + second + third + fourth + seen))
}

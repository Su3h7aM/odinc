package main

import "base:intrinsics"

add :: proc "contextless" (x, y: int) -> int {
	return x + y
}

mul :: proc "contextless" (x, y: int) -> int {
	return x * y
}

apply :: proc "contextless" (operation: proc "contextless" (_: int, _: int) -> int, x, y: int) -> int {
	return operation(x, y)
}

main :: proc "contextless" () {
	operation: proc "contextless" (_: int, _: int) -> int = add
	first := operation(4, 5)
	operation = mul
	second := operation(3, 2)
	third := apply(add, 1, 2)
	fourth := apply(mul, 2, 3)
	intrinsics.syscall(60, uintptr(first + second + third + fourth))
}

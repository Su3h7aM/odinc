package main

import "base:intrinsics"

pick :: proc "contextless" (a: int, b: int = 2, c: int = 4) -> int {
	return a * 100 + b * 10 + c
}

order_code :: proc "contextless" (order: intrinsics.Atomic_Memory_Order) -> int {
	return int(order)
}

main :: proc() {
	first := pick(1, c = 3)
	second := pick(b = 5, a = 1)
	code := second - first + order_code(order = .Seq_Cst)
	intrinsics.syscall(60, uintptr(code))
}

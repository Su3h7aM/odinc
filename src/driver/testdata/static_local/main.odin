package main

import "base:intrinsics"

next_id :: proc "contextless" () -> int {
	@(static) counter: int = 5
	counter += 1
	return counter
}

slot_address :: proc "contextless" () -> ^int {
	@(static) slot := 7
	return &slot
}

clobber :: proc "contextless" (depth: int) -> int {
	buffer: [32]int
	for i in 0 ..< len(buffer) { buffer[i] = depth + i }
	if depth > 0 { return clobber(depth - 1) + buffer[3] }
	return buffer[5]
}

main :: proc() {
	a := next_id()
	b := next_id()
	kept := slot_address()
	kept^ = 9
	sink := clobber(6)
	same := slot_address() == kept
	code := a + b * 10 + kept^ + sink * 0
	if same { code += 0 } else { code += 100 }
	intrinsics.syscall(60, uintptr(code))
}

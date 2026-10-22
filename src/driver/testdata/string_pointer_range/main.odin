package main

import "base:intrinsics"

sum :: proc(text: ^string) -> int {
	result := 0
	for character, offset in text { result += int(character) + offset }
	return result
}

main :: proc() {
	text := "aé"
	assert(sum(&text) == 331)
	intrinsics.syscall(60, uintptr(0))
}

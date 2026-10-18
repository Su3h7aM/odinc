package main

import "base:intrinsics"

main :: proc() {
	escaped := "A\x41\u00e9\101\e"
	raw := `a\nb`
	block := """
		ab
		c
		"""


	code: rune = '\e'
	intrinsics.syscall(60, uintptr(len(escaped) + len(raw) + len(block) + int(code)))
}

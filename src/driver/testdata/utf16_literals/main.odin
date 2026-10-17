package main

import "base:intrinsics"

main :: proc "contextless" () {
	text: string16 = "A😀"
	value: cstring16 = "A😀"
	empty: cstring16 = ""
	code := 0
	if len(text) == 3 { code += 1 }
	if text[1] == 0xd83d { code += 2 }
	if text[2] == 0xde00 { code += 4 }
	if value == "A😀" { code += 8 }
	if empty == "" { code += 16 }
	intrinsics.syscall(60, uintptr(code))
}

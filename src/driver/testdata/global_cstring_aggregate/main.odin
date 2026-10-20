package main

import "base:intrinsics"

Global_Strings :: struct {
	name:  cstring,
	paths: [2]cstring,
}

global_strings: Global_Strings = {
	name  = "main",
	paths = {"left", "right"},
}
global_name: cstring = "global"

main :: proc() {
	code := 42
	if global_name != "global" { code += 8 }
	if global_strings.name != "main" { code += 1 }
	if global_strings.paths[0] != "left" { code += 2 }
	if global_strings.paths[1] != "right" { code += 4 }
	intrinsics.syscall(60, uintptr(code))
}

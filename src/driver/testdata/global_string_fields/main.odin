package main

import "base:intrinsics"

Entry :: struct {
	delta:  int,
	cutoff: string,
}

entries := [?]Entry{{0, ""}, {1, "5"}, {2, "25"}}

main :: proc() {
	code := 0
	for entry in entries {
		code += entry.delta
	}
	code += len(entries[2].cutoff)
	code += int(entries[1].cutoff[0]) - '0'
	intrinsics.syscall(60, uintptr(code))
}

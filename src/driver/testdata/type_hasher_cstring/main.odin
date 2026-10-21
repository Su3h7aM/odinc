package main

import "base:intrinsics"

// Expected values are the official compiler's results (ODIN_ROOT set to its tree, Linux x64).
main :: proc() {
	code := 0
	buffer := [3]u8{'h', 'i', 0}
	heap_key := cstring(&buffer[0])
	literal: cstring = "hi"
	empty: cstring = ""
	nothing: cstring = nil
	hasher := intrinsics.type_hasher_proc(cstring)
	if hasher(&literal, 0) == 8300543724848622112 { code += 1 }
	if hasher(&literal, 12345) == 2996082488436527704 { code += 2 }
	if hasher(&empty, 12345) == 2885783399502049850 { code += 4 }
	if hasher(&nothing, 0) == 1 { code += 8 }
	if hasher(&heap_key, 0) == 8300543724848622112 { code += 16 }

	m: map[cstring]int
	m[literal] = 1
	m[heap_key] = 5
	m[empty] = 7
	_, found := m[cstring("hx")]
	if len(m) == 2 && m[literal] == 5 && m[cstring("")] == 7 && !found { code += 32 }
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"

bytes :: #load("payload.bin")
text :: #load("payload.bin", string)
words :: #load("payload.bin", []u16)
global_bytes := #load("payload.bin")
global_words := #load("payload.bin", []u16)
Holder :: struct {
	data: []u16,
}
holder := Holder{#load("payload.bin", []u16)}

main :: proc() {
	local := #load("payload.bin")
	if len(bytes) != 3 || len(text) != 3 || len(words) != 1 { intrinsics.syscall(60, uintptr(1)) }
	if bytes[0] != 'A' || text[2] != 'C' || local[1] != 'B' { intrinsics.syscall(60, uintptr(2)) }
	if words[0] != 0x4241 || global_words[0] != 0x4241 || holder.data[0] != 0x4241 { intrinsics.syscall(60, uintptr(3)) }
	if global_bytes[2] != 'C' || len(global_words) != 1 || len(holder.data) != 1 { intrinsics.syscall(60, uintptr(4)) }
	intrinsics.syscall(60, uintptr(42))
}

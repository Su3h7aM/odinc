package main

import "base:intrinsics"

Rank :: enum u8 {
	Middle = 7,
	Low    = 2,
	High   = 19,
	Last   = 4,
}
Alias :: distinct Rank
Buffer :: [int(max(Rank))]u8

main :: proc() {
	buffer: Buffer
	code := 0
	if min(Rank) == .Low { code += 1 }
	if max(Rank) == .High { code += 2 }
	if min(Alias) == .Low { code += 4 }
	if max(Alias) == .High { code += 8 }
	if len(buffer) == 19 { code += 16 }
	intrinsics.syscall(60, uintptr(code))
}

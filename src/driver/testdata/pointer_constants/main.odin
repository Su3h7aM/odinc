package main

import "base:intrinsics"

ALL_BITS :: rawptr(~uintptr(0))
SMALL :: rawptr(uintptr(8))
HIGH_BIT :: rawptr(uintptr(1) << 63)
ROUND_TRIP :: uintptr(ALL_BITS)
global: rawptr = SMALL

main :: proc() {
	result := 83
	if uintptr(ALL_BITS) != ~uintptr(0) { result = 1 }
	if uintptr(HIGH_BIT) != uintptr(1) << 63 { result = 2 }
	if ROUND_TRIP != ~uintptr(0) { result = 3 }
	if uintptr(global) != 8 { result = 4 }
	value := uintptr(8)
	pointer := rawptr(value)
	if pointer != SMALL { result = 5 }
	zero := rawptr(uintptr(0))
	if zero != nil { result = 6 }
	function := (proc "contextless" ())(ALL_BITS)
	if function == nil { result = 7 }
	intrinsics.syscall(60, uintptr(result))
}

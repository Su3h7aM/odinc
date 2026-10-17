package sample

import "base:intrinsics"

calls: u8
fallbacks: u8

status :: proc "contextless" (ok: bool) -> (u8, bool) {
	calls += 1
	return 7, ok
}

fallback :: proc "contextless" () -> u8 {
	fallbacks += 1
	return 3
}

main :: proc "contextless" () {
	status_fn: proc "contextless" (ok: bool) -> (u8, bool) = status
	first := (status(true)) or_else fallback()
	second := status_fn(false) or_else fallback()
	intrinsics.syscall(60, uintptr(first + second + calls * 10 + fallbacks * 20))
}

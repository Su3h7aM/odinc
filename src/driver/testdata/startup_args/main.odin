package main

import "base:intrinsics"

main :: proc "contextless" () {
	intrinsics.syscall(60, 0)
}

package main

import "base:intrinsics"

main :: proc() {
	W :: "Hellope"
	X :: cstring(W)
	Y :: string(X)

	w := W
	_ = w
	x: cstring = X
	y: string = Y
	z := string(x)
	code := len(x) + len(y) + len(z) + len(W) + len(X) + len(Y)
	if z == W {
		code += 1
	}
	intrinsics.syscall(60, uintptr(code))
}

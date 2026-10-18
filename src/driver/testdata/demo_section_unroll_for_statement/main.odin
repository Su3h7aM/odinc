package main

import "base:intrinsics"

Foo_Enum :: enum {
	A = 1,
	B,
	C = 6,
	D,
}

main :: proc() {
	code := 0
	#unroll for x, i in 1 ..< 4 {
		code += x * (i + 1)
	}
	#unroll for _ in "Hello, 世界" {
		code += 1
	}
	#unroll for elem, idx in ([4]int{1, 4, 9, 16}) {
		code += elem + idx
	}
	#unroll for elem in Foo_Enum {
		code += int(elem)
	}
	intrinsics.syscall(60, uintptr(code))
}

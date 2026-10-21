package main

import "base:runtime"
import "core:math/big"
import "lib"

Foo :: struct {
	d: [dynamic]int,
}

P := &Foo{}

@(init)
setup :: proc "contextless" () {
	context = runtime.default_context()
	append(&P.d, 1, 2, 3)
	if len(P.d) != 3 {
		lib.code = 1
	}
}

@(fini)
cleanup :: proc "contextless" () {
	context = runtime.default_context()
	if len(P.d) != 3 {
		lib.code += 2
	} else if P.d[0] != 1 || P.d[1] != 2 || P.d[2] != 3 {
		lib.code += 2
	}
	delete(P.d)
	i := &big.Int{}
	defer big.int_destroy(i)
	if err := big.set(i, 7); err != nil {
		lib.code += 32
	} else if i.used != 1 {
		lib.code += 64
	}
}

main :: proc() {
	context = runtime.default_context()
	if len(P.d) != 3 {
		lib.code += 16
	}
}

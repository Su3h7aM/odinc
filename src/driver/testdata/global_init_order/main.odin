package main

import "base:intrinsics"
import "lib"

b_val := make_b()
main_stamp := lib.tick()
a_val := 5
c := a_val + 2
first := second + 1
second := 10

make_b :: proc "contextless" () -> int { return 7 }

@(init)
bump :: proc "contextless" () { counter += 1 }

counter: int

main :: proc() {
	intrinsics.syscall(60, uintptr(lib.x + c + b_val + first + counter * 100 + lib.lib_stamp * 10 + main_stamp))
}

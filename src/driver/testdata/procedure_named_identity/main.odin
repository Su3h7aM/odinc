package main

import "base:intrinsics"
import "base:runtime"

A :: proc(x := 3) -> int
B :: proc(x := 3) -> int
C :: #type proc(x := 3) -> int
D :: A

identity :: proc(x: int) -> int {
	return x
}

main :: proc() {
	if A == B { intrinsics.syscall(60, 42) }
	if typeid_of(A) == typeid_of(B) { intrinsics.syscall(60, 43) }
	if A == C { intrinsics.syscall(60, 44) }
	if typeid_of(A) == typeid_of(C) { intrinsics.syscall(60, 45) }
	if typeid_of(A) != typeid_of(D) { intrinsics.syscall(60, 46) }
	if _, ok := type_info_of(A).variant.(runtime.Type_Info_Named); !ok { intrinsics.syscall(60, 47) }

	callback: A = identity
	if callback(3) != 3 { intrinsics.syscall(60, 48) }
	callback_b: B = callback
	if callback_b(4) != 4 { intrinsics.syscall(60, 49) }
	anonymous: proc(x: int) -> int = callback_b
	if anonymous(5) != 5 { intrinsics.syscall(60, 50) }
	cast_callback: B = B(callback)
	if cast_callback(6) != 6 { intrinsics.syscall(60, 51) }
	alias_callback: D = callback
	if alias_callback(7) != 7 { intrinsics.syscall(60, 54) }
	nil_callback: A = nil
	if nil_callback != nil { intrinsics.syscall(60, 52) }
	callback_any: any = callback
	if _, ok := callback_any.(A); !ok { intrinsics.syscall(60, 53) }
}

package main

import "base:intrinsics"

Holder :: struct {
	m:  Maybe(int),
	s:  []int,
	mp: map[int]int,
	d:  [dynamic]int,
	a:  any,
	u:  union {
		int,
		bool,
	},
	p:  ^int,
	t:  typeid,
}

clear_holder :: proc(h: ^Holder) {
	h.m = nil
	h.s = nil
	h.mp = nil
	h.d = nil
	h.a = nil
	h.u = nil
	h.p = nil
	h.t = nil
}

set_then_clear_deferred :: proc(h: ^Holder) {
	if true {
		defer if true {
			h.m = nil
		}
		h.m = 9
	}
}

main :: proc() {
	h: Holder
	seven := 7
	h.m = seven
	h.u = seven
	code := 0
	if h.m != nil { code += 1 }
	if h.u != nil { code += 2 }
	clear_holder(&h)
	if h.m == nil { code += 4 }
	if h.u == nil { code += 8 }
	if h.p == nil && h.t == nil { code += 16 }
	set_then_clear_deferred(&h)
	if h.m == nil { code += 32 }
	local: Maybe(int) = seven
	local = nil
	if local == nil { code += 64 }
	intrinsics.syscall(60, uintptr(code))
}

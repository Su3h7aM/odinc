package sample

import "base:intrinsics"

Pair :: struct {
	h: f32,
	n: int,
}

Reversed :: struct {
	n: int,
	h: f32,
}

bump :: proc(p: Pair) -> Pair {
	return Pair{h = p.h + 1, n = p.n + 1}
}

bump_reversed :: proc(r: Reversed) -> Reversed {
	return Reversed{n = r.n + 1, h = r.h + 1}
}

main :: proc() {
	q := bump(Pair{h = 1.5, n = 4})
	r := bump_reversed(Reversed{n = 3, h = 0.5})
	code := 0
	if q.h != 2.5 { code += 1 }
	if q.n != 5 { code += 2 }
	if r.n != 4 { code += 4 }
	if r.h != 1.5 { code += 8 }
	intrinsics.syscall(60, uintptr(code))
}

package main

import "base:intrinsics"

magnitude :: proc(c: complex128) -> f64 {
	return abs(c)
}

conjugate_sum :: proc(q: quaternion128) -> f32 {
	c := conj(q)
	return abs(q) + real(c) + imag(c) + jmag(c) + kmag(c)
}

abs256 :: proc(q: quaternion256) -> f64 {
	return abs(q)
}

real256 :: proc(q: quaternion256) -> f64 {
	return real(conj(q))
}

main :: proc() {
	code := 0
	a: complex64 = complex64(3 + 4i)
	b: complex128 = 3 + 4i
	if abs(a) == 5 { code += 1 }
	if abs(b) == 5 { code += 2 }
	if magnitude(5.0 + 12.0i) == 13 { code += 4 }
	five := 5.0
	if abs(3 + 4i) == five { code += 8 }
	if conj(a) == complex64(3 - 4i) { code += 16 }
	if conj(b) == 3 - 4i { code += 32 }
	if abs(conj(b)) == 5 { code += 64 }
	if conjugate_sum(quaternion(x = 0, y = 1, z = 2, w = 2)) == 2 { code += 128 }
	values := [3]complex128{3 + 4i, 5 + 12i, 8 + 15i}
	total := 0.0
	for i in 0 ..< len(values) { total += abs(values[i]) }
	if total == 35 { code += 256 }
	for i in 0 ..< len(values) { values[i] = conj(values[i]) }
	if values[0] == 3 - 4i && values[1] == 5 - 12i && values[2] == 8 - 15i { code += 512 }
	if abs256(quaternion(x = 1, y = 2, z = 2, w = 0)) == 3 { code += 1024 }
	if real256(quaternion(x = 1, y = 2, z = 2, w = 4)) == 4 { code += 2048 }
	intrinsics.syscall(60, uintptr(code))
}

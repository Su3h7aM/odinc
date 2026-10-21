package main

import "base:intrinsics"

Half_Union :: union {
	f16,
	int,
}

main :: proc() {
	code := 0
	table := make(map[f16]int)
	table[1.5] = 7
	table[2.5] = 9
	if table[1.5] == 7 { code += 1 }
	if table[2.5] == 9 { code += 2 }
	a := Half_Union(f16(1.5))
	b := Half_Union(f16(1.5))
	c := Half_Union(2)
	if a == b { code += 4 }
	if a != c { code += 8 }
	first := quaternion(w = 16, x = 17, y = 18, z = 19)
	second := quaternion(w = 16, x = 17, y = 18, z = 19)
	third := quaternion(w = 16, x = 17, y = 18, z = 20)
	if first == second && first != third { code += 16 }
	intrinsics.syscall(60, uintptr(code))
}

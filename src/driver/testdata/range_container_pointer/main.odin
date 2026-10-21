package main

import "base:intrinsics"

main :: proc() {
	code := 0
	slice := []int{10, 20, 30}
	total := 0
	for value in &slice { total += value }
	if total != 60 { code += 1 }
	weighted := 0
	for value, i in &slice { weighted += value * (i + 1) }
	if weighted != 140 { code += 2 }
	array := [4]int{1, 2, 3, 4}
	product := 1
	for value in &array { product *= value }
	if product != 24 { code += 4 }
	position := 0
	#reverse for value in &slice {
		if value != slice[2 - position] { code += 8 }
		position += 1
	}
	if position != 3 { code += 16 }
	intrinsics.syscall(60, uintptr(code + 42))
}

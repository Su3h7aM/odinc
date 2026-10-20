package main

import "base:intrinsics"

calls: i32 = 0
seq: i32 = 0
left_at: i32 = -1
right_at: i32 = -1

note_deref :: proc(m: ^matrix[2, 2]i32) -> ^matrix[2, 2]i32 {
	calls += 1
	return m
}

note_left :: proc(m: ^matrix[2, 2]i32) -> ^matrix[2, 2]i32 {
	left_at = seq
	seq += 1
	return m
}

note_right :: proc(field, other: ^matrix[2, 2]i32) -> ^matrix[2, 2]i32 {
	right_at = seq
	seq += 1
	field^[0, 0] = 100
	return other
}

main :: proc() {
	code := 0
	field := matrix[2, 2]i32{
		1, 2,
		3, 4,
	}
	other := matrix[2, 2]i32{
		10, 0,
		0, 10,
	}
	negated := -note_deref(&field)^
	posited := +note_deref(&field)^
	if calls != 2 { code += 1 }
	if negated[0, 0] != -1 || posited[1, 1] != 4 { code += 2 }
	total := note_left(&field)^ + note_right(&field, &other)^
	if left_at != 0 || right_at != 1 { code += 4 }
	if total[0, 0] != 110 || total[1, 1] != 14 || field[0, 0] != 100 { code += 8 }
	half := matrix[2, 2]f16{
		0, 1,
		2, 3,
	}
	neg_half := -half
	neg_inf := 1 / neg_half[0, 0]
	pos_inf := 1 / half[0, 0]
	if !(neg_inf == pos_inf) || neg_half[0, 1] != -1 { code += 16 }
	intrinsics.syscall(60, uintptr(42 + code))
}

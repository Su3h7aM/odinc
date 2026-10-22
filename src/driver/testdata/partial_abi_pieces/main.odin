package main

import "base:intrinsics"

E :: enum u8 {
	None,
	Failed,
}
F :: enum u8 {
	None,
	Failed,
}
G :: enum u8 {
	None,
	Failed,
}
Inner :: union #shared_nil {
	E,
	F,
}
Status :: union #shared_nil {
	Inner,
	G,
}

three :: proc(value: [3]u8) -> [3]u8 { return value }
five :: proc(value: [5]u8) -> [5]u8 { return value }
six :: proc(value: [6]u8) -> [6]u8 { return value }
seven :: proc(value: [7]u8) -> [7]u8 { return value }
status :: proc() -> Status { return G.Failed }

main :: proc() {
	a := three({1, 2, 3})
	b := five({4, 5, 6, 7, 8})
	c := six({9, 10, 11, 12, 13, 14})
	d := seven({15, 16, 17, 18, 19, 20, 21})
	result := 0
	if a[0] == 1 && a[2] == 3 { result += 1 }
	if b[0] == 4 && b[4] == 8 { result += 2 }
	if c[0] == 9 && c[5] == 14 { result += 4 }
	if d[0] == 15 && d[6] == 21 { result += 8 }
	value := status()
	if failure, ok := value.(G); ok && failure == .Failed { result += 16 }
	intrinsics.syscall(60, uintptr(result))
}

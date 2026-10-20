package main

import "base:intrinsics"

Record :: struct {
	value: int,
}

conditional :: proc(target: ^int) -> (result: int) {
	defer target^ = result
	defer if true { result = 9 }
	return 2
}

multiple :: proc(target: ^int) -> (result: int) {
	defer target^ = result
	defer { result = 7; result += 1 }
	result = 3
	return
}

compound :: proc(target: ^int) -> (result: int) {
	defer target^ = result
	defer result += 1
	return 4
}

loop :: proc(target: ^int) -> (result: int) {
	defer target^ = result
	defer for i in 0 ..< 3 { result = i + 10 }
	return 5
}

field :: proc(target: ^int) -> (result: Record) {
	defer target^ = result.value
	defer result.value = 9
	result.value = 6
	return
}

indexed :: proc(target: ^int) -> (result: [2]int) {
	defer target^ = result[0]
	defer result[0] = 9
	result[0] = 7
	result[1] = 3
	return
}

nested :: proc(target: ^int) -> (result: int) {
	defer target^ = result
	defer {
		callback := proc() -> (inner: int) {
			defer if true { inner = 7 }
			return 2
		}
		result = callback()
	}
	return 8
}

main :: proc() {
	a, b, c, d, e, f, g: int
	x := conditional(&a)
	y := multiple(&b)
	z := compound(&c)
	w := loop(&d)
	record := field(&e)
	array := indexed(&f)
	v := nested(&g)
	result := x + y + z + w + record.value + array[0] + array[1] + v
	if a != 9 || b != 8 || c != 5 || d != 12 || e != 9 || f != 9 || g != 2 { result = 99 }
	intrinsics.syscall(60, uintptr(result))
}

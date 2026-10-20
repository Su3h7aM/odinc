package sample

import "base:intrinsics"

Triple :: struct {
	a, b, c: int,
}

Record :: struct {
	name:  string,
	id:    i32,
	level: i32,
	tag:   string,
}

sum_triple :: proc(t: Triple) -> int {
	return t.a + t.b + t.c
}

make_triple :: proc(n: int) -> Triple {
	return Triple{n, n + 1, n + 2}
}

check_record :: proc(r: Record) -> bool {
	return r.name == "file" && r.id == 3 && r.level == 4 && r.tag == "proc"
}

make_record :: proc(id: i32) -> Record {
	return Record{"file", id, id + 1, "proc"}
}

mixed :: proc(x: int, r: Record, y: int) -> int {
	if !check_record(r) { return -1 }
	return x * 10 + y + int(r.id)
}

many :: proc(a, b, c, d, e, f, g, h: int) -> int {
	return h * 100 + g * 10 + a + b + c + d + e + f
}

count_dyn :: proc(d: [dynamic]u8) -> int {
	return len(d) + cap(d)
}

main :: proc() {
	code := 15
	if sum_triple(make_triple(1)) != 6 { code += 1 }
	if !check_record(make_record(3)) { code += 2 }
	if mixed(1, make_record(3), 2) != 15 { code += 4 }
	if many(1, 1, 1, 1, 1, 1, 1, 3) != 316 { code += 8 }
	record := make_record(3)
	if !check_record(record) { code += 16 }

	data := make([]int, 3)
	data[0], data[1], data[2] = 1, 2, 3
	delete(data)

	text := "abc"
	buf := make([]u8, 3)
	copy(buf, text)
	delete(string(buf))

	m := make(map[int]int)
	m[1] = 2
	delete(m)

	d: [dynamic]u8
	append(&d, 1)
	if count_dyn(d) < 2 { code += 32 }
	delete(d)

	intrinsics.syscall(60, uintptr(code))
}

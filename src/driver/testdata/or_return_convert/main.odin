package sample

import "base:intrinsics"

Alloc_Kind :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid,
}

Error :: union {
	Alloc_Kind,
	string,
}

check_alloc :: proc(n: int) -> Alloc_Kind {
	if n == 1 { return .Out_Of_Memory }
	if n == 2 { return .Invalid }
	return .None
}

step :: proc(n: int) -> Error {
	kind := check_alloc(n)
	kind or_return
	return nil
}

get :: proc(n: int) -> (int, Alloc_Kind) {
	if n == 1 { return 0, .Out_Of_Memory }
	return n * 3, .None
}

split :: proc(n: int) -> (value: int, err: Error) {
	value = get(n) or_return
	return
}

check_bool :: proc(n: int) -> (int, bool) {
	return n + 1, n > 0
}

bool_step :: proc(n: int) -> (res: int, ok: bool) {
	res = check_bool(n) or_return
	ok = true
	return
}

main :: proc() {
	code := 0
	if step(0) != nil { code += 1 }
	if k, ok := step(1).(Alloc_Kind); ok { code += 2 * int(k) }
	if k, ok := step(2).(Alloc_Kind); ok { code += 4 * int(k) }
	value, err := split(3)
	if err != nil || value != 9 { code += 16 }
	value1, err1 := split(1)
	if k, ok := err1.(Alloc_Kind); ok { code += 32 * int(k) }
	if value1 != 0 { code += 64 }
	res0, ok0 := bool_step(0)
	if ok0 || res0 != 0 { code += 128 }
	res4, ok4 := bool_step(4)
	if !ok4 || res4 != 5 { code += 256 }
	intrinsics.syscall(60, uintptr(code))
}

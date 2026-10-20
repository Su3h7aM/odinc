package sample

import "base:intrinsics"

as_int :: proc(v: any) -> (value: int, ok: bool) {
	n := v.(int) or_return
	return n + 1, true
}

as_bool :: proc(v: any) -> bool {
	n := v.(int) or_return
	return n > 0
}

named_result :: proc(v: any) -> (value: int, ok: bool) {
	value = v.(int) or_return
	ok = true
	return
}

main :: proc() {
	code := 0
	five: any = 5
	text: any = "x"
	if value, ok := as_int(five); !ok || value != 6 { code += 1 }
	if _, ok := as_int(text); ok { code += 2 }
	if !as_bool(five) { code += 4 }
	if as_bool(text) { code += 8 }
	if value, ok := named_result(five); !ok || value != 5 { code += 16 }
	if _, ok := named_result(text); ok { code += 32 }
	intrinsics.syscall(60, uintptr(code))
}

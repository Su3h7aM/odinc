package main

import "base:intrinsics"

Number :: distinct u32
calls: int

get_id :: proc "contextless" () -> typeid {
	calls += 1
	return typeid_of(Number)
}

main :: proc() {
	code := 0
	info := type_info_of(Number)
	if info.size == 4 && info.align == 4 { code += 1 }
	if info.id == typeid_of(Number) { code += 2 }
	id := typeid_of(Number)
	if type_info_of(id) == info { code += 4 }
	if type_info_of(get_id()) == info && calls == 1 { code += 8 }
	invalid := transmute(typeid)u64(0xffff_ffff_ffff_ffff)
	invalid_info := type_info_of(invalid)
	zero := transmute(typeid)u64(0)
	if invalid_info != nil && invalid_info.id == zero && invalid_info.size == 0 && invalid_info.align == 0 && type_info_of(zero) == invalid_info { code += 16 }
	intrinsics.syscall(60, uintptr(code))
}

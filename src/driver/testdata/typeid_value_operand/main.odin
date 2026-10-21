package main

import "base:intrinsics"

is_byte :: proc(id: typeid) -> bool {
	return id == byte
}

main :: proc() {
	code := 0
	value: any = u8(5)
	id := type_info_of(value.id).id
	if id != byte { code += 1 }
	if id == rawptr { code += 2 }
	pointer: any = rawptr(nil)
	if type_info_of(pointer.id).id != rawptr { code += 4 }
	boxed := any{value.data, id}
	if boxed.id != byte { code += 8 }
	if !is_byte(id) { code += 16 }
	intrinsics.syscall(60, uintptr(code + 42))
}

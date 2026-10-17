package main

import "base:intrinsics"

get_text :: proc() -> string {
	_ = intrinsics.syscall(1, 1, uintptr(raw_data("!")), 1)
	return "XY"
}

main :: proc "contextless" () {
	text := "XY"
	bytes := cast([]u8)text
	nil_bytes: []u8
	nil_text: string
	text16: string16 = "A😀"
	empty := ""
	empty_bytes := cast([]u8)empty
	code := 0
	text_data := raw_data(text)
	byte_data := raw_data(bytes)
	text16_data := raw_data(text16)
	if text_data[0] == 88 && text_data[1] == 89 { code += 1 }
	if byte_data[0] == 88 && byte_data[1] == 89 && byte_data == text_data { code += 2 }
	if raw_data(nil_bytes) == nil { code += 4 }
	if len(empty) == 0 && len(empty_bytes) == 0 && raw_data(empty_bytes) == raw_data(empty) { code += 8 }
	if text16_data[0] == 65 && text16_data[1] == 0xd83d && text16_data[2] == 0xde00 { code += 16 }
	if raw_data(nil_text) == nil { code += 32 }
	once := raw_data(get_text())
	if once[0] == 88 { code += 64 }
	intrinsics.syscall(60, uintptr(code))
}

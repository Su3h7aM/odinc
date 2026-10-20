package main

import "base:intrinsics"

E :: enum {
	A,
	B,
}

take :: proc(value: u8) -> u8 { return value }
convert :: proc(value: i64) -> u8 { return auto_cast value }

main :: proc() {
	wide: i64 = 300
	narrow: u8 = auto_cast wide
	inferred := auto_cast wide
	other: i64 = 3
	sum: u8 = auto_cast other + auto_cast other
	selected: E = auto_cast .B
	nested: E = auto_cast (.B if true else .A)
	address := rawptr(&wide)
	pointer: ^i64 = auto_cast address
	result := int(narrow) + int(take(auto_cast wide)) + int(convert(wide)) + int(sum)
	if inferred != 300 || selected != .B || nested != .B || pointer^ != 300 { result = 99 }
	if !(narrow == auto_cast wide) || auto_cast wide == narrow { result = 98 }
	small: i8 = -1
	large: u64 = ~u64(0)
	fraction: f32 = 2.75
	integer: i64 = 2
	if !(auto_cast small == large) || auto_cast small < large { result = 97 }
	if !(auto_cast fraction == integer) || !(auto_cast i64(44) == narrow) { result = 96 }
	negative: i64 = -1
	huge: u128 = ~u128(0)
	half: f16 = 3.5
	whole: i64 = 3
	if !(auto_cast negative == huge) || !(auto_cast half == whole) { result = 95 }
	intrinsics.syscall(60, uintptr(result))
}

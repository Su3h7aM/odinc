package main

import "base:intrinsics"

main :: proc "contextless" () {
	code := 0
	unsigned: u8 = 240
	signed: i8 = -120
	positive: i64 = 0x7fff_ffff_ffff_ffff
	negative: i64 = -0x8000_0000_0000_0000
	if intrinsics.saturating_add(unsigned, 30) == 255 && intrinsics.saturating_sub(unsigned, 250) == 0 { code += 1 }
	if intrinsics.saturating_add(signed, -30) == -128 && intrinsics.saturating_sub(signed, 30) == -128 { code += 2 }
	if intrinsics.saturating_add(positive, 1) == positive && intrinsics.saturating_sub(negative, 1) == negative { code += 4 }
	if intrinsics.saturating_add(unsigned, 1) == 241 && intrinsics.saturating_sub(signed, -30) == -90 { code += 8 }
	when intrinsics.type_is_integer(i64) && intrinsics.type_is_array([4]u8) { code += 16 }
	intrinsics.syscall(60, uintptr(code))
}

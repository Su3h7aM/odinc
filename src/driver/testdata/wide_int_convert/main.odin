package main

import "base:intrinsics"

mix :: proc(acc, value: u128) -> u128 {
	return acc * 31 + value
}

main :: proc() {
	acc: u128 = 0
	pick: u128
	pick = 5
	acc = mix(acc, pick)

	big: u128 = (u128(1) << 100) | 0x1234_5678_9abc_def0
	acc = mix(acc, big)
	acc = mix(acc, big >> 70)
	count := 37
	acc = mix(acc, big << uint(count))
	acc = mix(acc, big >> uint(count))
	acc = mix(acc, big &~ u128(0xff))
	acc = mix(acc, big | 0xf0)
	acc = mix(acc, big ~ (u128(1) << 127))
	acc = mix(acc, big + big)
	acc = mix(acc, big - (u128(1) << 101))
	acc = mix(acc, big * 3)

	acc = mix(acc, u128(u64(big)))
	acc = mix(acc, u128(u8(big)))
	acc = mix(acc, u128(int(big >> 64)))
	acc = mix(acc, u128(i64(big)))
	acc = mix(acc, u128(i8(big)))

	m8: i8 = -1
	m16: i16 = -2
	m32: i32 = -3
	m64: i64 = -4
	m_int: int = -5
	acc = mix(acc, u128(m8))
	acc = mix(acc, u128(m16))
	acc = mix(acc, u128(m32))
	acc = mix(acc, u128(m64))
	acc = mix(acc, u128(m_int))
	acc = mix(acc, u128(u8(200)))
	acc = mix(acc, u128(u64(1) << 63))

	neg: i128 = -7
	acc = mix(acc, u128(neg))
	acc = mix(acc, u128(neg >> 3))
	acc = mix(acc, u128(neg * neg))
	acc = mix(acc, u128(i128(big) >> 90))

	lo: u128 = u128(1) << 64
	if big > lo { acc = mix(acc, 1) }
	if big < big + 1 { acc = mix(acc, 2) }
	if lo + 1 == (u128(1) << 64) + 1 { acc = mix(acc, 3) }
	if neg < 0 { acc = mix(acc, 4) }
	if big >= u128(0x1234_5678_9abc_def0) { acc = mix(acc, 5) }

	folded := u64(acc) ~ u64(acc >> 64)
	intrinsics.syscall(60, uintptr(folded & 0xff))
}

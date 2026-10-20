package main

import "base:intrinsics"

Big :: bit_set[0 ..< 128;u128]
Color :: enum {
	Red,
	Green,
	Blue,
}
Colors :: bit_set[Color]
Small :: bit_set[0 ..< 64;u64]

main :: proc() {
	bits: u128 = (u128(1) << 3) | (u128(1) << 70) | (u128(1) << 127) | 0xff
	set := transmute(Big)bits
	total := 0
	for i in set {
		total += i
	}
	if 127 in set { total += 10 }
	for i in transmute(bit_set[0 ..< 128])bits {
		total += i
	}
	if 64 in set { total += 100 }
	if 70 not_in set { total += 1000 }
	count := intrinsics.count_ones(transmute(u128)(set & Big{70, 64}))
	total += int(count)

	colors := Colors{.Green, .Blue}
	for color in colors {
		total += int(color)
	}

	small: Small = {5, 63}
	for bit in small {
		total += bit
	}

	intrinsics.syscall(60, uintptr(total & 0xff))
}

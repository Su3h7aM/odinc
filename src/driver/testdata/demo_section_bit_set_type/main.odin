package main

import "base:intrinsics"

main :: proc() {
	code := 0
	{
		Day :: enum {
			Sunday,
			Monday,
			Tuesday,
			Wednesday,
			Thursday,
			Friday,
			Saturday,
		}

		Days :: distinct bit_set[Day]
		WEEKEND :: Days{.Sunday, .Saturday}

		d: Days
		d = {.Sunday, .Monday}
		e := d + WEEKEND
		e += {.Monday}

		if .Saturday in e {
			code += 1
		}
		if .Wednesday not_in e {
			code += 2
		}
		X :: .Saturday in WEEKEND
		if X {
			code += 4
		}
		if card(e) == 3 {
			code += 8
		}
	}
	{
		x: bit_set['A' ..= 'Z']
		#assert(size_of(x) == size_of(u32))
		y: bit_set[0 ..= 8;u16]

		x += {'F'}
		if 'F' in x {
			code += 16
		}
		x -= {'F'}
		if 'F' not_in x {
			code += 32
		}

		y += {1, 4, 2}
		if 2 in y {
			code += 64
		}
	}
	{
		Letters :: bit_set['A' ..= 'Z']
		a := Letters{'A', 'B'}
		b := Letters{'A', 'B', 'C', 'D', 'F'}
		c := Letters{'A', 'B'}

		if a <= b && a < b && b >= a && b > a && !(a < c) && !(c > a) {
			code += 128
		}
	}
	intrinsics.syscall(60, uintptr(code))
}

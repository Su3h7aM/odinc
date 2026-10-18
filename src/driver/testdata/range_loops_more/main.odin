package main

import "base:intrinsics"

check :: proc(condition: bool) {
	if !condition { intrinsics.debug_trap() }
}

Color :: enum {
	Red,
	Green,
	Blue,
}

Sparse :: enum u8 {
	Low  = 1,
	Mid  = 4,
	High = 9,
}

Flag :: enum {
	A,
	B,
	C,
	D,
}

Flags :: bit_set[Flag]

Ranged :: enum u8 {
	Two   = 2,
	Three = 3,
	Five  = 5,
}

main :: proc() {
	values := [4]int{1, 2, 3, 4}
	number := 0
	#reverse for value in values {
		number = number * 10 + value
	}
	check(number == 4321)

	last_index := -1
	#reverse for value, index in values {
		if index == 3 { last_index = value }
	}
	check(last_index == 4)

	slice := values[:]
	weighted := 0
	#reverse for value, index in slice {
		weighted += value * index
	}
	check(weighted == 20)

	counts := [Color]int {
		.Red   = 1,
		.Green = 2,
		.Blue  = 3,
	}
	total := 0
	for count in counts {
		total += count
	}
	check(total == 6)

	by_position := 0
	for count, color in counts {
		by_position += count * int(color)
	}
	check(by_position == 8)

	reverse_counts := 0
	#reverse for count in counts {
		reverse_counts = reverse_counts * 10 + count
	}
	check(reverse_counts == 321)

	colors := 0
	for color in Color {
		colors += int(color)
	}
	check(colors == 3)

	skipped := 0
	for color in Color {
		if color == .Green { continue }
		skipped += int(color)
	}
	check(skipped == 2)

	sparse := 0
	for member, position in Sparse {
		sparse += int(member) * 10 + position
	}
	check(sparse == 143)

	stopped := -1
	for color in Color {
		if color == .Blue { break }
		stopped = int(color)
	}
	check(stopped == 1)

	flags := Flags{.A, .C, .D}
	order := 0
	for flag in flags {
		order = order * 10 + int(flag)
	}
	check(order == 23)

	reverse_order := 0
	#reverse for flag in flags {
		reverse_order = reverse_order * 10 + int(flag)
	}
	check(reverse_order == 320)

	empty: Flags
	empty_count := 0
	for flag in empty {
		empty_count += 1
	}
	check(empty_count == 0)

	ranged := bit_set[Ranged]{.Two, .Five}
	ranged_order := 0
	for position in ranged {
		ranged_order = ranged_order * 10 + int(position)
	}
	check(ranged_order == 25)

	reverse_ranged := 0
	#reverse for position in ranged {
		reverse_ranged = reverse_ranged * 10 + int(position)
	}
	check(reverse_ranged == 52)

	text := "a\u00e9\u20ac"
	text_total := 0
	for value, index in text {
		text_total += int(value) + index * 1000
	}
	check(text_total == 12694)

	text_indices := 0
	first_rune := 0
	#reverse for value, index in text {
		if text_indices == 0 { first_rune = int(value) }
		text_indices = text_indices * 10 + index
	}
	check(text_indices == 310)
	check(first_rune == 8364)

	empty_text := ""
	empty_runes := 0
	for value in empty_text {
		empty_runes += 1
	}
	check(empty_runes == 0)

	units := [3]u16{104, 105, 955}
	wide := transmute(string16)units[:]
	wide_total := 0
	for value, index in wide {
		wide_total += int(value) + index * 1000
	}
	check(wide_total == 4164)

	wide_indices := 0
	#reverse for value, index in wide {
		wide_indices = wide_indices * 10 + index
	}
	check(wide_indices == 210)
}

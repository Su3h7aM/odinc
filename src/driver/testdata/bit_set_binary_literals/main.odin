package main

import "base:intrinsics"

Flag :: enum {
	A,
	B,
	C,
}
Flags :: bit_set[Flag;u8]
Wide :: bit_set[0 ..< 128;u128]
Offset :: bit_set[-3 ..= 4]

main :: proc() {
	result := 73
	flags := Flags{.A, .B}
	if flags + {.B, .C} != {.A, .B, .C} { result = 1 }
	if flags - {.B} != {.A} { result = 2 }
	if flags & {.B} != {.B} { result = 3 }
	if flags &~ {.B} != {.A} { result = 4 }
	if flags | {.C} != {.A, .B, .C} { result = 5 }
	if flags ~ {.B, .C} != {.A, .C} { result = 6 }
	if !(flags == {.A, .B}) || flags == {} || flags != {.A, .B} { result = 7 }
	if !(flags < {.A, .B, .C}) || flags < {.A, .B} { result = 8 }
	if !(flags <= {.A, .B}) || flags <= {.A, .C} { result = 9 }
	if !(flags > {}) || flags > {.A, .B} { result = 10 }
	if !(flags >= {.A}) || flags >= {.A, .C} { result = 11 }
	if ({.C}) + flags != {.A, .B, .C} { result = 12 }
	if flags + ({.C}) != {.A, .B, .C} { result = 13 }
	if !({.A} < flags) || !({.A, .B} >= flags) { result = 14 }
	if .A not_in flags || .C in flags { result = 15 }
	FOLDED :: Flags{.A, .B} + {.B, .C} - {.A}
	if FOLDED != (Flags{.B, .C}) { result = 16 }
	element := Flag.C
	if flags + {element, .B} != {.A, .B, .C} { result = 17 }
	flags += {element}
	flags -= {.B}
	if flags != {.A, .C} { result = 18 }
	flags |= {.B}
	flags &= {.B, .C}
	flags ~= {.B}
	flags &~= {.A}
	if flags != {.C} { result = 19 }
	wide := Wide{3, 70}
	if wide + {70, 127} != {3, 70, 127} { result = 20 }
	if !(wide < {3, 70, 127}) || wide <= {4, 127} { result = 21 }
	index := 127
	if wide + {index} - {70} != {3, 127} { result = 22 }
	if 70 not_in wide || 71 in wide { result = 23 }
	negative := -3
	offset: Offset = {negative, 4}
	if offset != {-3, 4} || !(offset > {}) { result = 24 }
	intrinsics.syscall(60, uintptr(result))
}

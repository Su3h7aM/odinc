package array_scalar_broadcast

import "core:fmt"

Pair :: struct {
	a: u16,
	b: u16,
}

Holder :: struct {
	name:   string,
	values: [3]f64,
	flags:  [2]bool,
}

give :: proc() -> [4]u8 {
	return 4
}

show :: proc(values: [4]u8) {
	fmt.println("arg", values)
}

main :: proc() {
	bytes: [4]byte = 8
	fmt.println(bytes)

	fmt.println(give())
	show(4)

	grid: [2][3]i32 = -7
	fmt.println(grid)

	reals: [3]f32 = 0.5
	fmt.println(reals)

	flags: [2]bool = true
	fmt.println(flags)

	pair := Pair{1, 2}
	pairs: [3]Pair = pair
	fmt.println(pairs)

	cube: [2][2]u8 = 3
	fmt.println(cube)

	holder := Holder {
		name   = "h",
		values = 2.5,
		flags  = false,
	}
	fmt.println(holder)

	later: [3]f64
	later = 2
	fmt.println(later)
}

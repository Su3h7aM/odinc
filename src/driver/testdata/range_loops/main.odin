package main

import "base:intrinsics"

Color :: enum {
	Red,
	Green,
	Blue,
}

check :: proc(condition: bool) {
	if !condition { intrinsics.debug_trap() }
}

main :: proc() {
	sum := 0
	for i in 0 ..< 4 { sum += i }
	check(sum == 6)
	for i in 1 ..= 3 { sum += i }
	check(sum == 12)
	check(sum == 12)

	count := 0
	for i in 0 ..< 10 {
		if i == 2 { continue }
		if i == 5 { break }
		count += 1
	}
	check(count == 4)

	outer := 0
	for i in 0 ..< 3 {
		for j in 0 ..< 3 {
			if j == 1 { break }
			outer += 1
		}
	}
	check(outer == 3)

	values := [3]int{1, 2, 3}
	for &value in values { value *= 10 }
	check(values[0] + values[1] + values[2] == 60)

	unrolled := 0
	#unroll for k in 0 ..< 4 { unrolled += k }
	check(unrolled == 6)
	#unroll for v in values { unrolled += v }
	check(unrolled == 66)

	slice := values[:]
	total := 0
	for value, index in slice { total += value * index }
	check(total == 80)

	floats := 0.0
	for x in 0.0 ..= 2.0 { floats += x }
	check(floats == 3)

	colors := 0
	for c in Color.Red ..= Color.Green { colors += int(c) }
	check(colors == 1)
}

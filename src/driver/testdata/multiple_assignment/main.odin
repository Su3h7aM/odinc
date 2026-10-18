package main

import "base:intrinsics"

pair :: proc "contextless" (counter: ^int) -> (int, int) {
	counter^ += 1
	return counter^ * 10, counter^ * 10 + 1
}

next :: proc "contextless" (counter: ^int) -> int {
	counter^ += 1
	return counter^
}

main :: proc "contextless" () {
	code := 0
	counter := 0
	first, second: int
	first, second = pair(&counter)
	if first == 10 && second == 11 && counter == 1 { code += 1 }
	_, second = pair(&counter)
	_, _ = pair(&counter)
	if second == 21 && counter == 3 { code += 2 }
	first, second = second, first
	if first == 21 && second == 10 { code += 4 }
	first, second = next(&counter), next(&counter)
	if first == 4 && second == 5 && counter == 5 { code += 8 }
	first, _, second = next(&counter), pair(&counter)
	if first == 6 && second == 71 && counter == 7 { code += 16 }
	buffer: [2]int
	index := 0
	index, buffer[index] = 1, 9
	if index == 1 && buffer[0] == 9 && buffer[1] == 0 { code += 32 }
	left: [2]int
	right: [2]int
	left[0] = 3
	right[0] = 8
	left, right = right, left
	if left[0] == 8 && right[0] == 3 { code += 64 }
	intrinsics.syscall(60, uintptr(code))
}

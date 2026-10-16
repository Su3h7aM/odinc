package main

main :: proc() {
	values: [4]int
	window := values[1:3]
	j := 2
	window[j] = 9
}

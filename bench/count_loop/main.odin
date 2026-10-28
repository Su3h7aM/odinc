package main

sum: u64

main :: proc() {
	for i in 0 ..< 100_000_000 {
		sum += u64(i)
	}
}

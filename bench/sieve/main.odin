package main

PRIME_LIMIT :: 1_000_000

prime_count: int

main :: proc() {
	composite := make([]bool, PRIME_LIMIT)
	defer delete(composite)
	prime_count = 0
	for i in 2 ..< PRIME_LIMIT {
		if composite[i] {
			continue
		}
		prime_count += 1
		for j := i * 2; j < PRIME_LIMIT; j += i {
			composite[j] = true
		}
	}
}

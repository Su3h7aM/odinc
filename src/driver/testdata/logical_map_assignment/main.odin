package main

logical_map_key :: proc() -> int { return 0 }

main :: proc() {
	entries: map[int]bool
	entries[logical_map_key()] ||= true
	entries[logical_map_key()] &&= false
}

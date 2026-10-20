package main

where_am_i :: proc(loc := #caller_location) -> int {
	return int(loc.line)
}

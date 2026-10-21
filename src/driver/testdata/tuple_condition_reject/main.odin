package main

pair :: proc() -> (bool, bool) { return true, false }

main :: proc() {
	if pair() {  }
}

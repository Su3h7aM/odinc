package main

classify :: proc(value: int) -> bool {
	switch value {
	case 1, 2:
		return true
	case:
		panic("unreachable value")
	}
}

main :: proc() {
	if !classify(2) { panic("classify") }
}

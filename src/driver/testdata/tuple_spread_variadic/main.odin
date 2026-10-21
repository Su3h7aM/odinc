package main

import "base:intrinsics"

calls: int

pair :: proc "contextless" () -> (int, int) {
	calls += 1
	return 3, 4
}

mixed :: proc "contextless" () -> (string, int) {
	calls += 1
	return "s", 7
}

var_any :: proc "contextless" (xs: ..any) -> int { return len(xs) }

two_any :: proc "contextless" (x, y: any) -> bool {
	first, first_ok := x.(int)
	second, second_ok := y.(int)
	return first_ok && second_ok && first == 3 && second == 4
}

check_mixed :: proc "contextless" (xs: ..any) -> bool {
	text, text_ok := xs[0].(string)
	number, number_ok := xs[1].(int)
	return text_ok && number_ok && text == "s" && number == 7
}

main :: proc() {
	code := 0
	if var_any(1, pair()) == 3 && calls == 1 { code += 1 }
	if two_any(pair()) && calls == 2 { code += 2 }
	if check_mixed(mixed()) && calls == 3 { code += 4 }
	intrinsics.syscall(60, uintptr(code))
}

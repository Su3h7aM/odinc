package check

import "core:testing"

@(test)
group_call_accepts_spread_and_named_arguments :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
g :: proc{g_ints, g_one}
g_ints :: proc(first: int, nums: ..int, scale := 1) -> int { return first }
g_one :: proc(x: string) -> int { return 0 }
xs: []int
main :: proc() {
	_ = g(1, ..xs)
	_ = g(1, ..xs, scale = 2)
	_ = g(1, 2, 3)
	_ = g(1, scale = 2)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, .None, "", 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
group_call_rejects_spread_not_last_and_unknown_name :: proc(t: ^testing.T) {
	rejections := []string {
		`package sample
g :: proc{g_ints, g_one}
g_ints :: proc(first: int, nums: ..int, scale := 1) -> int { return first }
g_one :: proc(x: string) -> int { return 0 }
xs: []int
main :: proc() {
	_ = g(1, 2, ..xs)
}
`,
		`package sample
g :: proc{g_ints, g_one}
g_ints :: proc(first: int, nums: ..int, scale := 1) -> int { return first }
g_one :: proc(x: string) -> int { return 0 }
main :: proc() {
	_ = g(1, nope = 3)
}
`,
	}
	for source in rejections {
		rejected, rejected_ok := check_procedure_source(t, transmute([]byte)source, .No_Matching_Overload)
		if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
	}
}

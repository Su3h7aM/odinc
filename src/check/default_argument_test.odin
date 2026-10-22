package check

import "core:testing"

// Omitted trailing arguments take constant and compound-literal defaults, as official Odin does.
@(test)
omitted_defaults_fill_calls :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Point :: struct { x, y: int }
scale :: proc(value: int, factor := 3, origin := Point{}) -> int { return value * factor + origin.x }
main :: proc() {
	_ = scale(2)
	_ = scale(2, 4)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, .None, "", 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

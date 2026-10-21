package check

import "core:testing"

@(test)
poly_names_resolve_by_declaration_order :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
T :: struct { x: u8 }
outer :: proc "contextless" (a: T, b: $U) -> u8 { return a.x }
later :: proc "contextless" (b: $T, a: T) -> T { return a }
bound :: proc "contextless" (x: $T, y: [2]T) -> T { return y[0] }
main :: proc "contextless" () {
	_ = outer(T{x = 1}, u8(2))
	_ = later(T{x = 1}, T{x = 2})
	_ = bound(u8(1), [2]u8{3, 4})
}
`,
	)
	procedure, ok := check_last_procedure_source(t, valid)
	if ok { testing.expect(t, procedure.body_state == .Complete) }
	rejected, rejected_ok := check_procedure_source(
		t,
		transmute([]byte)string(
			`package sample
T :: struct { x: u8 }
later :: proc "contextless" (b: $T, a: T) -> T { return a }
main :: proc "contextless" () { _ = later(2, T{x = 1}) }
`,
		),
		.Conversion,
		"",
	)
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}

package check

import "core:testing"

@(test)
optional_results_and_assertions_read_their_first_value :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" (ok: bool, shape: Shape) -> u8 {
	value: u8
	value = optional(ok)
	return value + optional(ok) + pick_u8(u8(1)) + shape.(u8) + (shape.(u8) or_else 0)
}
Shape :: union { u8 }
optional :: proc "contextless" (ok: bool) -> (u8, bool) #optional_ok { return 1, ok }
pick_u8 :: proc "contextless" (value: u8) -> (u8, bool) #optional_ok { return value, value == 1 }
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
union_assertion_takes_only_the_exact_variant :: proc(t: ^testing.T) {
	rejected := transmute([]byte)string(
		`package sample
main :: proc "contextless" (value: Union_A) -> B { return value.(B) }
A :: distinct u8
B :: distinct u8
Union_A :: union { A }
`,
	)
	procedure, ok := check_procedure_source(t, rejected, .Mismatched_Types, "")
	if ok { testing.expect(t, procedure.body_state == .Invalid) }
}

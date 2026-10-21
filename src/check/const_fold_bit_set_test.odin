package check

import "core:testing"

@(test)
explicit_backing_bit_set_membership_folds_in_when :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Flag :: enum u32 { A, B, C }
Flags :: distinct bit_set[Flag; u32]
SET :: Flags{.B, .C}
when .A in SET {
	#panic("A is not in SET")
}
when .C not_in SET {
	#panic("C is in SET")
}
main :: proc "contextless" () {
	#assert(.B in SET)
	#assert(.A not_in SET)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

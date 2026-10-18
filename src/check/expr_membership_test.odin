package check

import "core:testing"

@(test)
runtime_membership_yields_bool_for_bit_sets_and_maps :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" (flags: Flags, keys: map[u8]bool) -> bool {
	return .A in flags && 1 in keys
}
Flag :: enum {A, B}
Flags :: bit_set[Flag]
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

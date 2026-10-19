package check

import "core:testing"

@(test)
simd_constant_declaration_broadcasts_scalar_constant :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Lanes :: #simd[4]u8
MIN_LANES: Lanes : u8(0xff)
probe :: proc "contextless" () -> Lanes { return MIN_LANES }
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "probe")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

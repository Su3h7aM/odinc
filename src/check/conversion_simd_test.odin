package check

import "core:testing"

@(test)
simd_constant_declaration_broadcasts_scalar_constant :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Lanes :: #simd[4]u8
MIN_LANES: Lanes : u8(0xff)
probe :: proc "contextless" () -> Lanes {
	wide := (#simd[4]u16)(MIN_LANES)
	broadcast := Lanes(7)
	return Lanes(wide)
}
fill :: proc "contextless" (c: u8) -> #simd[4]u8 {
	lanes: #simd[4]u8 = c
	lanes = c
	return c
}
`,
	)
	for name in ([?]string{"probe", "fill"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name)
		if ok { testing.expect(t, procedure.body_state == .Complete) }
	}
}

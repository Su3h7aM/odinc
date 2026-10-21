package check

import "core:testing"

// A fixed `#soa[N]T` literal lists element values row by row, like an array
// literal over the element type. The spread columns are an implementation
// detail: naming one (`a = 1` at the top level) must not resolve.
@(test)
soa_fixed_literal_accepts_row_elements :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
V :: struct {a: i32, b: f64, c: f32}
fixed_global := #soa[3]V{{a = 1, b = 1.0, c = 1.0}, {a = 2, b = 2.0, c = 1.0}, {a = 3, b = 3.0, c = 1.0}}
main :: proc() {
	_ = fixed_global
	local := #soa[3]V{{a = 1, b = 1.0, c = 1.0}, {a = 2, b = 2.0, c = 1.0}, {a = 3, b = 3.0, c = 1.0}}
	sparse := #soa[4]V{0 ..= 1 = {a = 7, b = 7.0, c = 7.0}, 3 = {a = 9, b = 9.0, c = 9.0}}
	_, _ = local, sparse
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

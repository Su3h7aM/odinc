package check

import "core:strings"
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
@(test)
soa_non_fixed_literals_accept_only_zero_initialization :: proc(t: ^testing.T) {
	cases := [?]struct {
		body, reason: string,
	} {
		{
			`slice: S = {}; values: D = {}; slice = S{}; values = D{}; other := #soa[dynamic]V{}; zero_slice :: S{}; zero_dynamic :: D{}; _, _, _, _, _ = slice, values, other, zero_slice, zero_dynamic`,
			"",
		},
		{`_ = #soa[]V{{1, 2}}`, "#soa slices are not supported for compound literals"},
		{`_ = #soa[dynamic]V{{1, 2}}`, "#soa dynamic arrays are not supported for compound literals"},
		{`_ = S{{1, 2}}`, "#soa slices and dynamic arrays are not supported for compound literals"},
		{`_ = D{{1, 2}}`, "#soa slices and dynamic arrays are not supported for compound literals"},
		{`slice: S = {{1, 2}}; _ = slice`, "#soa slices and dynamic arrays are not supported for compound literals"},
		{`values: D = {{1, 2}}; _ = values`, "#soa slices and dynamic arrays are not supported for compound literals"},
	}
	for example in cases {
		source, allocation_error := strings.concatenate(
			{"package sample\nV :: struct {a, b: int}\nS :: #soa[]V\nD :: #soa[dynamic]V\nmain :: proc() { ", example.body, "\n}\n"},
			context.allocator,
		)
		if !testing.expect_value(t, allocation_error, nil) { continue }
		defer delete(source, context.allocator)
		kind := Expression_Diagnostic_Kind.Invalid_Operand if example.reason != "" else .None
		count := 1 if example.reason != "" else 0
		procedure, ok := check_procedure_source(t, transmute([]byte)source, expected_kind = kind, expected_reason = example.reason, diagnostic_count = count)
		if ok && example.reason == "" { testing.expect(t, procedure.body_state == .Complete) }
	}
}

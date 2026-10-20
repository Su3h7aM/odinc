package check

import "core:testing"

@(test)
auto_cast_rejects_unrepresentable_constant :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
    value: u8 = auto_cast 300
    _ = value
}
`)
	_, ok := check_procedure_source(t, source, .Conversion, diagnostic_count = 1)
	testing.expect(t, ok)
}

@(test)
length_argument_hint_does_not_retype_a_bound_variable :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
consume :: proc(value: uint) {}
main :: proc() {
    values: []u8
    count := len(values)
    consume(count)
}
`,
	)
	_, ok := check_procedure_source(t, source, .Conversion, diagnostic_count = 1)
	testing.expect(t, ok)
}

@(test)
procedure_directive_requires_a_procedure_scope :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
NAME :: #procedure
main :: proc() {}
`)
	_, ok := check_procedure_source(t, source, .Unsupported, "Procedure_Directive_Scope", diagnostic_count = 1)
	testing.expect(t, ok)
}

@(test)
local_generic_record_checks_its_where_clause :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc() {
    Buffer :: struct($N: int) where N > 1 { values: [N]int }
    buffer: Buffer(0)
    _ = buffer
}
`,
	)
	_, ok := check_procedure_source(t, source, diagnostic_count = 0, type_diagnostic_count = 1)
	testing.expect(t, ok)
}

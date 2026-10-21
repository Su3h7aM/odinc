package check

import "core:testing"

@(test)
generic_specialization_sees_earlier_parameter_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
read :: proc(value: $T, callback: $C/proc(T)) {}
main :: proc() {
	value := 1
	read(value, proc(value: int) {})
	read(1, proc(value: int) {})
	read(1, proc(value: u8) {})
}
`,
	)
	_, ok := check_procedure_source(t, source, .None, "", 0, type_diagnostic_count = 0)
	testing.expect(t, ok)
}

package check

import "core:testing"

@(test)
load_directive_validates_nested_enum_before_reading_file :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Letter :: enum u8 { A = 65 }
Record :: struct { letters: [1]Letter }
main :: proc() { records := #load("", []Record) }
`,
	)
	_, ok := check_procedure_source(t, source, expected_kind = .Invalid_Operand, expected_reason = "'#load' could not read file", diagnostic_count = 1)
	testing.expect(t, ok)
}

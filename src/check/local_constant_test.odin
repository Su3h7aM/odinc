package check

import "core:testing"

@(test)
block_constants_and_procedures_resolve_before_their_declaration :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () -> u8 {
	return twice(LIMIT)
	twice :: proc "contextless" (value: u8) -> u8 {
		return value + value
	}
	LIMIT :: 2
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
mutually_recursive_block_procedures_resolve :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () -> u8 {
		return first(1)
		first :: proc "contextless" (value: u8) -> u8 {
			if value == 0 { return 0 }
			return second(value - 1)
		}
		second :: proc "contextless" (value: u8) -> u8 {
			if value == 0 { return 0 }
			return first(value - 1)
		}
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
explicitly_typed_block_constants_resolve :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () -> u8 {
	LIMIT : u8 : 2
	return twice(LIMIT)
	twice :: proc "contextless" (value: u8) -> u8 {
		return value + value
	}
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

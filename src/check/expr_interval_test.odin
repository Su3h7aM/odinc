package check

import "core:testing"

@(test)
switch_interval_case_accepts_bounds_of_the_tag_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
classify :: proc "contextless" (value: int) -> int {
	switch value {
	case 0 ..< 10, 20 ..= 30:
		return 1
	}
	return 0
}
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "classify")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
array_interval_key_fills_every_covered_index :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
table :: proc "contextless" () -> [4]int { return [4]int{0 ..< 2 = 1, 2 ..= 3 = 2} }
`)
	procedure, ok := check_procedure_source(t, source, procedure_name = "table")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
array_interval_key_rejects_empty_interval :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
table :: proc "contextless" () -> [4]int { return [4]int{3 ..< 1 = 1} }
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operand, "", 1, "table")
	testing.expect(t, ok)
}

@(test)
switch_rejects_duplicate_constant_cases :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
	value := false
	switch value {
	case false:
	case false:
	}
}
`)
	_, _ = check_procedure_source(t, source, .Message, "Duplicate case 'false'\n\tprevious case at (5:7)", diagnostic_count = 1)
}

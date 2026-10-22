package check

import "core:testing"

@(test)
return_expands_optional_results_with_declared_conversions :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Count :: union { int }
Flag :: union { bool }
Value :: union { int, f64 }
lookup :: proc "contextless" (items: map[int]int, key: int) -> (Count, Flag) { return items[key] }
lookup_parenthesized :: proc "contextless" (items: map[int]int, key: int) -> (Count, Flag) { return (items[key]) }
asserted :: proc "contextless" (value: Value) -> (int, bool) { return value.? }
asserted_parenthesized :: proc "contextless" (value: Value) -> (int, bool) { return (value.?) }
asserted_converted :: proc "contextless" (value: Value) -> (Count, Flag) { return value.(int) }
boxed :: proc "contextless" (items: map[int]int, key: int) -> (Value, Flag) { return items[key] }
main :: proc "contextless" () {
	items: map[int]int
	number: int
	status: any
	number, status = items[1]
	value: Value = 1
	number, status = value.(int)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if !testing.expect(t, ok) { return }
	testing.expect(t, procedure.body_state == .Complete)
	invalid := transmute([]byte)string(
		`package sample
lookup :: proc "contextless" (items: map[int]int, key: int) -> (int, bool, int) { return items[key] }
main :: proc "contextless" () {}
`,
	)
	_, rejected := check_procedure_source(t, invalid, .Unsupported, "Return_Arity", diagnostic_count = 1)
	testing.expect(t, rejected)
	mismatched := transmute([]byte)string(
		`package sample
Count :: distinct int
lookup :: proc "contextless" (items: map[int]int, key: int) -> (Count, bool) { return items[key] }
main :: proc "contextless" () {}
`,
	)
	_, converted := check_procedure_source(t, mismatched, .Conversion, "", diagnostic_count = 1)
	testing.expect(t, converted)
}

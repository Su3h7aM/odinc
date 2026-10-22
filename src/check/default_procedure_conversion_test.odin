package check

import "core:testing"

@(test)
named_procedure_defaults_retain_assignment_conversions :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Callback :: #type proc "contextless" (value: int) -> int
first :: proc "contextless" (value: int) -> int { return value + 1 }
current := first
named: Callback = first
invoke :: proc "contextless" (callback: Callback = first) -> int { return callback(3) }
mutable :: proc "contextless" (callback: Callback = current) -> int { return callback(3) }
unchanged :: proc "contextless" (callback: Callback = named) -> int { return callback(3) }
literal :: proc "contextless" (callback: Callback = proc "contextless" (value: int) -> int { return value + 9 }) -> int { return callback(3) }
main :: proc "contextless" () {
	_, _, _, _ = invoke(), mutable(), unchanged(), literal()
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if !testing.expect(t, ok) { return }
	testing.expect(t, procedure.body_state == .Complete)
	invalid := transmute([]byte)string(
		`package sample
Callback :: #type proc "contextless" (value: int) -> int
first :: proc "contextless" (value: int) -> int { return value }
factory :: proc "contextless" () -> proc "contextless" (value: int) -> int { return first }
invoke :: proc "contextless" (callback: Callback = factory()) -> int { return callback(3) }
main :: proc "contextless" () {}
`,
	)
	_, rejected := check_procedure_source(t, invalid, .Unsupported, "Default_Conversion", diagnostic_count = 1)
	testing.expect(t, rejected)
}

package check

import "core:testing"

@(test)
type_call_hints_composite_literal_argument :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
Socket :: distinct i64
Inner :: struct { value: int }
Outer :: struct { inner: Inner }
main :: proc "contextless" () {
	socket := Socket({})
	nested := Outer({inner = {value = 7}})
	scalar := int(int(5))
	_, _, _ = socket, nested, scalar
}
`,
	)
	procedure, ok := check_procedure_source(t, valid, diagnostic_count = 0)
	if !testing.expect(t, ok) { return }
	testing.expect(t, procedure.body_state == .Complete)

	invalid_field := transmute([]byte)string(
		`package sample
Address :: struct { value: u64 }
Socket :: distinct i64
Inner :: struct { value: int }
Outer :: struct { inner: Inner }
main :: proc "contextless" () {
	_ = Outer({unknown = 1})
}
`,
	)
	rejected, rejected_ok := check_procedure_source(t, invalid_field)
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }

	invalid_value := transmute([]byte)string(
		`package sample
Address :: struct { value: u64 }
Socket :: distinct i64
Inner :: struct { value: int }
Outer :: struct { inner: Inner }
main :: proc "contextless" () {
	_ = Outer({inner = {value = "wrong"}})
}
`,
	)
	rejected, rejected_ok = check_procedure_source(t, invalid_value)
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}

@(test)
ordinary_procedure_call_keeps_parameter_composite_hint :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Pair :: struct {left, right: int}
consume :: proc "contextless" (value: Pair) {}
main :: proc "contextless" () {
	consume({left = 1, right = 2})
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

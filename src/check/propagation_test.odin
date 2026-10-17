package check

import "core:testing"

@(test)
expression_or_else_checks_bool_and_nil_pointer_status_pairs :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" (ok: bool, ptr: ^u8) -> u8 {
	value := bool_status(ok) or_else 9
	_ = pointer_status(ok, ptr) or_else 8
	return value
}
bool_status :: proc "contextless" (ok: bool) -> (u8, bool) { return 7, ok }
pointer_status :: proc "contextless" (ok: bool, ptr: ^u8) -> (u8, ^u8) { return 7, ptr }
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	invalid_sources := [?][]byte {
		transmute([]byte)string(`package sample
main :: proc "contextless" (ok: bool) -> u8 { return ok or_else 9 }
`),
		transmute([]byte)string(`package sample
main :: proc "contextless" (ptr: ^u8) -> ^u8 { return ptr or_else ptr }
`),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) -> u8 { return status(ok) or_else 9 }
status :: proc "contextless" (ok: bool) -> bool { return ok }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) -> u8 { return status(ok) or_else 9 }
status :: proc "contextless" (ok: bool) -> (u8, u8, bool) { return 7, 8, ok }
`,
		),
	}
	for source in invalid_sources {
		rejected, rejected_ok := check_procedure_source(t, source)
		if !rejected_ok { continue }
		testing.expect(t, rejected.body_state == .Invalid)
	}
}

@(test)
expression_or_return_checks_status_and_return_shapes :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" (ok: bool) -> bool {
	return status(ok) or_return
}
status :: proc "contextless" (ok: bool) -> (bool, bool) { return true, ok }
status_only :: proc "contextless" (ok: bool) -> bool { return ok }
check :: proc "contextless" (ok: bool) -> bool {
	status_only(ok) or_return
	return true
}
check_parenthesized :: proc "contextless" (ok: bool) -> bool {
	((status_only(ok) or_return))
	return true
}
named :: proc "contextless" (ok: bool) -> (value: u8, failed: bool) {
	value = 3
	_ = status(ok) or_return
	return
}
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	invalid_sources := [?][]byte {
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) -> (u8, bool) { return status(ok) or_return, false }
status :: proc "contextless" (ok: bool) -> (u8, bool) { return 7, ok }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) -> u8 { return status(ok) or_return }
status :: proc "contextless" (ok: bool) -> (u8, u8) { return 7, 8 }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) -> u8 {
	defer status(ok) or_return
	return 1
}
status :: proc "contextless" (ok: bool) -> (u8, bool) { return 7, ok }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) -> bool {
	status(ok) or_return
	return true
}
status :: proc "contextless" (ok: bool) -> (bool, bool) { return true, ok }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) -> bool {
	((status(ok) or_return))
	return true
}
status :: proc "contextless" (ok: bool) -> (bool, bool) { return true, ok }
`,
		),
	}
	for source in invalid_sources {
		rejected, rejected_ok := check_procedure_source(t, source)
		if !rejected_ok { continue }
		testing.expect(t, rejected.body_state == .Invalid)
	}
}

@(test)
or_return_preserves_nominal_pointer_status_identity :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" (value: Value_Ptr, status: Value_Ptr) -> Value_Ptr {
	return pointer_pair(value, status) or_return
}
pointer_pair :: proc "contextless" (value, status: Value_Ptr) -> (Value_Ptr, Value_Ptr) {
	return value, status
}
Value_Ptr :: distinct ^u8
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	invalid := transmute([]byte)string(
		`package sample
main :: proc "contextless" (value: Value_Ptr, status: Status_Ptr) -> Value_Ptr {
	return pointer_pair(value, status) or_return
}
pointer_pair :: proc "contextless" (value: Value_Ptr, status: Status_Ptr) -> (Value_Ptr, Status_Ptr) {
	return value, status
}
Value_Ptr :: distinct ^u8
Status_Ptr :: distinct ^u8
`,
	)
	rejected, rejected_ok := check_procedure_source(t, invalid)
	if !testing.expect(t, rejected_ok) { return }
	testing.expect(t, rejected.body_state == .Invalid)
}

package check

import "core:testing"

@(test)
expression_or_else_infers_union_assertion_from_context :: proc(t: ^testing.T) {
	// Official accepts a union type assertion whose result type comes from the assignment context.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	v: union { int, f64 }
	i: int
	i = v.? or_else 123
}
`)
	_, ok := check_procedure_source(t, source)
	testing.expect(t, ok)
}

@(test)
expression_or_else_checks_map_index_and_comma_ok :: proc(t: ^testing.T) {
	// Official accepts both `m[k] or_else d` and `value, ok := m[k]`.
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	items: map[string]int
	value := items["key"] or_else 3
	other, ok := items["key"]
	_ = value
	_ = other
	_ = ok
}
`,
	)
	_, ok := check_procedure_source(t, source)
	testing.expect(t, ok)
}

@(test)
expression_or_branch_accepts_multiple_call_results :: proc(t: ^testing.T) {
	// Official accepts multiple values before the final error result in `or_continue`.
	source := transmute([]byte)string(
		`package sample
Error :: enum { None, Failure }
main :: proc "contextless" () {
	for {
		first, second := values() or_continue
		_ = first
		_ = second
		break
	}
}
values :: proc "contextless" () -> (int, int, Error) { return 1, 2, .None }
`,
	)
	_, ok := check_procedure_source(t, source)
	testing.expect(t, ok)
}

@(test)
expression_or_break_checks_status_and_target_context :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" (ok: bool) -> u8 {
	for {
		value := bool_status(ok) or_break
		return value
	}
	return 0
}
continue_check :: proc "contextless" (ok: bool) -> u8 {
	for {
		value := bool_status(ok) or_continue
		return value
	}
	return 0
}
continue_label_check :: proc "contextless" (ok: bool) {
	outer: for {
		for { (bool_status(ok)) or_continue outer }
	}
}
continue_indirect_check :: proc "contextless" (ok: bool) {
	status_fn := bool_status
	for { status_fn(ok) or_continue }
}
bool_status :: proc "contextless" (ok: bool) -> (u8, bool) { return 7, ok }
status_only :: proc "contextless" (ok: bool) -> bool {
	for { status_only_value(ok) or_break; break }
	return true
}
status_only_value :: proc "contextless" (ok: bool) -> bool { return ok }
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	invalid_sources := [?][]byte {
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) { status(ok) or_break }
status :: proc "contextless" (ok: bool) -> (u8, bool) { return 1, ok }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) {
	status(ok) or_continue
}
status :: proc "contextless" (ok: bool) -> (u8, bool) { return 1, ok }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) {
	for { defer status(ok) or_break; break }
}
status :: proc "contextless" (ok: bool) -> (u8, bool) { return 1, ok }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) {
	for { defer status(ok) or_continue; break }
}
status :: proc "contextless" (ok: bool) -> (u8, bool) { return 1, ok }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) {
	for { status(ok) or_break missing }
}
status :: proc "contextless" (ok: bool) -> (u8, bool) { return 1, ok }
`,
		),
		transmute([]byte)string(
			`package sample
main :: proc "contextless" (ok: bool) {
	bad: switch 1 {
	case 1: status(ok) or_continue bad
	}
}
status :: proc "contextless" (ok: bool) -> (u8, bool) { return 1, ok }
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
enum_status :: proc "contextless" (ok: bool) -> Mode {
	if ok { return .None }
	return .Failed
}
enum_check :: proc "contextless" (ok: bool) -> Mode {
	enum_status(ok) or_return
	return .None
}
discard_value :: proc "contextless" (ok: bool) -> bool {
	status(ok) or_return
	return true
}
discard_parenthesized :: proc "contextless" (ok: bool) -> bool {
	((status(ok) or_return))
	return true
}
Mode :: enum u8 { None, Failed }
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
	for name in ([?]string{"discard_value", "discard_parenthesized"}) {
		discarded, discarded_ok := check_procedure_source(t, valid, procedure_name = name)
		if discarded_ok { testing.expect(t, discarded.body_state == .Complete) }
	}

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

@(test)
or_return_assigns_status_and_unpacks_extra_results :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
Status :: enum u8 { None, Failed }
Failure :: union #shared_nil { Status }
main :: proc "contextless" (ok: bool) -> (value: u8, err: Failure) {
	value = status(ok) or_return
	counted(ok) or_return
	return
}
status :: proc "contextless" (ok: bool) -> (u8, Status) {
	if ok { return 7, .None }
	return 0, .Failed
}
counted :: proc "contextless" (ok: bool) -> (int, Status) { return 1, .None }
split :: proc "contextless" (ok: bool) -> (a: u8, b: u8, err: Failure) {
	a, b = triple(ok) or_return
	return
}
declare :: proc "contextless" (ok: bool) -> (err: Failure) {
	a, b := triple(ok) or_return
	return
}
triple :: proc "contextless" (ok: bool) -> (u8, u8, Status) { return 1, 2, .None }
`,
	)
	for name in ([?]string{"main", "split", "declare"}) {
		procedure, ok := check_procedure_source(t, valid, procedure_name = name)
		if !ok { return }
		testing.expect(t, procedure.body_state == .Complete)
	}

	invalid := transmute([]byte)string(
		`package sample
Status :: enum u8 { None, Failed }
Other :: enum u8 { None }
Failure :: union #shared_nil { Status }
main :: proc "contextless" () -> (value: u8, err: Failure) {
	value = other() or_return
	return
}
other :: proc "contextless" () -> (u8, Other) { return 1, .None }
`,
	)
	rejected, rejected_ok := check_procedure_source(t, invalid)
	if !testing.expect(t, rejected_ok) { return }
	testing.expect(t, rejected.body_state == .Invalid)
}

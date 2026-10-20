package check

import "core:testing"

@(test)
local_generic_call_checks_where_and_shares_the_instance :: proc(t: ^testing.T) {
	// Official Odin accepts a local generic with a where clause called twice with `[]u16`, and an unused local generic.
	source := transmute([]byte)string(
		`package sample
main :: proc() {
	show :: proc(s: []$T) where size_of(T) == 2 {}
	later :: proc(s: []$T) {}
	s: []u16
	show(s)
	show(s)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, .None, "", 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
local_generic_call_rejects_a_where_clause_that_is_false :: proc(t: ^testing.T) {
	// Official Odin: "'where' clause evaluated to false" for `T :: u8`.
	source := transmute([]byte)string(`package sample
main :: proc() {
	show :: proc(s: []$T) where size_of(T) == 2 {}
	s: []u8
	show(s)
}
`)
	rejected, rejected_ok := check_procedure_source(t, source)
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}

@(test)
local_generic_body_cannot_capture_an_outer_local :: proc(t: ^testing.T) {
	// Official Odin: "Undeclared name: outer".
	source := transmute([]byte)string(`package sample
main :: proc() {
	outer := 3
	show :: proc(s: []$T) {
		_ = outer
	}
	s: []u16
	show(s)
}
`)
	rejected, rejected_ok := check_procedure_source(t, source)
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}

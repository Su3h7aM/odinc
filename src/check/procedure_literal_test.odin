package check

import "core:testing"

@(test)
procedure_literals_check_bodies_without_capturing_locals :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	OFFSET :: 2
	add :: proc "contextless" (value: u8) -> u8 { return value + OFFSET }
	callback := proc "contextless" (value: u8) -> u8 { return value + 1 }
	value := callback(add(3))
}
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
	invalid := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	value: u8
	callback := proc "contextless" () -> u8 { return value }
}
`,
	)
	rejected, rejected_ok := check_procedure_source(t, invalid, .Undeclared_Name)
	if !rejected_ok { return }
	testing.expect(t, rejected.body_state == .Invalid)
}

@(test)
procedure_literal_bodies_keep_their_own_branches_and_defers :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" () -> u8 {
	for {
		callback := proc "contextless" () -> u8 {
			for { break }
			defer {}
			return 1
		}
		value := callback()
		if value == 1 { break }
	}
	return 2
}
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	outer_loop := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	for {
		callback := proc "contextless" () { break }
		callback()
	}
}
`,
	)
	branch, branch_ok := check_procedure_source(t, outer_loop, .Unsupported, "Branch_Target")
	if branch_ok { testing.expect(t, branch.body_state == .Invalid) }

	defer_return := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	defer {
		callback := proc "contextless" () -> u8 { return 1 }
		value := callback()
		return
	}
}
`,
	)
	returned, returned_ok := check_procedure_source(t, defer_return, .Unsupported, "Return_In_Defer")
	if returned_ok { testing.expect(t, returned.body_state == .Invalid) }
}

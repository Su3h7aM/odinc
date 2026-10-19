package check

import "core:testing"

@(test)
proc_group_call_resolves_implicit_selector_argument_by_member_parameter :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Errno :: enum i32 { NONE, TIMEDOUT }
Mode :: enum i32 { NONE }
wait :: proc "contextless" (value: Errno) -> Errno { return value }
other :: proc "contextless" (value: Mode) -> Mode { return value }
pick :: proc{wait, other}
timed_out :: proc "contextless" () -> Errno { return pick(.TIMEDOUT) }
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "timed_out")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
proc_group_call_resolves_literal_argument_by_member_shape :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
two :: proc "contextless" (value: [2]int) -> int { return 2 }
three :: proc "contextless" (value: [3]int) -> int { return 3 }
pick :: proc{two, three}
triple :: proc "contextless" () -> int { return pick({1, 2, 3}) }
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "triple")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

package check

import "core:testing"

@(test)
proc_group_call_binds_polymorphic_names_for_later_parameters :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
append_one :: proc "contextless" (array: ^$T/[dynamic]$E, arg: E) -> int { return 1 }
append_flag :: proc "contextless" (flag: bool) -> int { return 0 }
add :: proc{append_one, append_flag}
add_value :: proc "contextless" (values: ^[dynamic]int) -> int { return add(values, 1) }
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "add_value")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

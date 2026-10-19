package check

import "core:testing"

@(test)
proc_group_soa_pattern_does_not_match_plain_dynamic_array :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
plain_many :: proc(array: ^$T/[dynamic]$E, args: ..E) -> int { return 0 }
soa_many :: proc(array: ^$T/#soa[dynamic]$E, args: ..E) -> int { return 1 }
add :: proc{plain_many, soa_many}
add_value :: proc(values: ^[dynamic]int) -> int { return add(values, 1) }
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "add_value")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

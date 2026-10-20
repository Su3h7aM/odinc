package check

import "core:testing"

@(test)
proc_group_where_clause_uses_bound_parameter_types :: proc(t: ^testing.T) {
	// Official accepts generic overload groups whose where clauses query parameter sizes.
	source := transmute([]byte)string(
		`package sample
syscall_two :: proc "contextless" (nr: uintptr, first: $T1, second: $T2) -> int
where size_of(first) <= size_of(uintptr), size_of(second) <= size_of(uintptr) { return 0 }
syscall_three :: proc "contextless" (nr: uintptr, first: $T1, second: $T2, third: $T3) -> int
where size_of(first) <= size_of(uintptr), size_of(second) <= size_of(uintptr), size_of(third) <= size_of(uintptr) { return 0 }
syscall :: proc { syscall_two, syscall_three }
main :: proc () {
	ts: [2]i64
	_ = syscall(uintptr(1), 0, &ts)
}
`,
	)
	_, ok := check_procedure_source(t, source)
	testing.expect(t, ok)
}

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

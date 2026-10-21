package check

import "core:testing"

@(test)
self_host_union_zero_and_group_argument_hints :: proc(t: ^testing.T) {
	_, ok := check_procedure_source(
		t,
		transmute([]byte)string(
			`package sample
U :: union {int, []int}
E :: enum {A, B}
poly :: proc(dst: ^[dynamic]$T, values: ..T) -> T { return values[0] }
other :: proc(dst: int) {}
push :: proc{poly, other}
main :: proc() {
 u := U{}
 a: [dynamic]E
 selected_enum: E = push(&a, E.A, .B)
 b: [dynamic]int
 selected_int: int = push(&b, 2 if len(a) == 0 else 1)
 #assert(type_of(u) == U)
 _ = selected_enum
 _ = selected_int
 _ = u
}
`,
		),
		diagnostic_count = 0,
	)
	testing.expect(t, ok)
}

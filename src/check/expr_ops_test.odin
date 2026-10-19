package check

import "core:testing"

@(test)
modulo_accepts_untyped_float_constant_as_integer_operand :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
nanos :: proc "contextless" (value: int) -> int { return value % 1e9 }
`)
	procedure, ok := check_procedure_source(t, source, procedure_name = "nanos")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
equality_compares_typeid_value_with_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
is_pointer_type :: proc "contextless" (id: typeid) -> bool { return id == rawptr }
`)
	procedure, ok := check_procedure_source(t, source, procedure_name = "is_pointer_type")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
bit_set_equality_accepts_composite_empty_set :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Flag :: enum {A, B}
Flags :: bit_set[Flag; u8]
is_empty :: proc "contextless" (options: Flags) -> bool { return options == {} }
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "is_empty")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
procedure_equality_compares_procedure_values :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
target :: proc "contextless" () {}
is_target :: proc "contextless" (value: proc "contextless" ()) -> bool { return value == target }
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "is_target")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
union_equality_accepts_assignable_variant :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Error_Kind :: enum {None, EOF}
Error :: union {Error_Kind, u8}
is_eof :: proc "contextless" (err: Error) -> bool { return err == Error_Kind.EOF || Error_Kind.EOF == err }
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "is_eof")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

@(test)
bit_set_accepts_set_union_difference_and_logic :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Flag :: enum {A, B, C}
Flags :: bit_set[Flag; u8]
combine :: proc "contextless" (first, second: Flags) -> Flags {
	return ((first + second) - second) & (first | second) ~ (first &~ second)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "combine")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

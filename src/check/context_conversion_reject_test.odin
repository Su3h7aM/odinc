package check

import "core:testing"

@(test)
generic_untyped_argument_must_fit_inferred_type :: proc(t: ^testing.T) {
	// Official: 128 cannot be represented by i8; its maximum is 127.
	source := transmute([]byte)string(
		`package sample
add :: proc "contextless" (left, right: $T) -> T { return left + right }
main :: proc "contextless" () { value: i8; _ = add(value, 128) }
`,
	)
	_, ok := check_procedure_source(t, source, .Conversion)
	testing.expect(t, ok)
}

@(test)
generic_typed_arguments_must_agree :: proc(t: ^testing.T) {
	// Official: Cannot assign value 'right' of type 'i64' to 'i32' in a procedure argument.
	source := transmute([]byte)string(
		`package sample
add :: proc "contextless" (left, right: $T) -> T { return left + right }
main :: proc "contextless" () { left: i32; right: i64; _ = add(left, right) }
`,
	)
	_, ok := check_procedure_source(t, source, .Unsupported, "Generic_Call_Pattern")
	testing.expect(t, ok)
}

@(test)
pointer_constant_requires_uintptr_source :: proc(t: ^testing.T) {
	// Official: Cannot cast 'u64(1)' as 'rawptr'; convert the integer to uintptr first.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () { _ = rawptr(u64(1)) }
`)
	_, ok := check_procedure_source(t, source, .Conversion)
	testing.expect(t, ok)
}

@(test)
variable_initializer_mismatch_names_declaration :: proc(t: ^testing.T) {
	// Official: Cannot assign value 'b' of type 'Maybe($T=int)' to 'Maybe($T=f32)' in a variable declaration.
	source := transmute([]byte)string(
		`package sample
Maybe :: union($T: typeid) { T }
main :: proc "contextless" () { a: Maybe(int) = 1; b := a; c: Maybe(f32) = b; _ = c }
`,
	)
	_, ok := check_procedure_source(t, source, .Conversion, "Cannot assign value 'b' of type 'Maybe($T=int)' to 'Maybe($T=f32)' in a variable declaration")
	testing.expect(t, ok)
}

@(test)
plain_field_does_not_enable_implicit_pointer_conversion :: proc(t: ^testing.T) {
	// Official: Cannot assign '^Derived' to '^Base' in a return statement.
	source := transmute([]byte)string(
		`package sample
Base :: struct { value: int }
Derived :: struct { before: int, base: Base }
main :: proc "contextless" (value: ^Derived) -> ^Base { return value }
`,
	)
	_, ok := check_procedure_source(t, source, .Mismatched_Types)
	testing.expect(t, ok)
}

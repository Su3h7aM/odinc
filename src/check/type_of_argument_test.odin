package check

import "core:testing"

@(test)
type_of_and_generic_instance_arguments_pass_typeid_parameters :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Box :: struct($T: typeid) { value: T }
print_id :: proc(id: typeid) {}
print_name :: proc($T: typeid) {}
main :: proc() {
	x := 1
	box := Box(int){9}
	print_id(type_of(x))
	print_name(type_of(box))
	print_name(Box(int))
	print_id(Box(int))
}
`,
	)
	_, ok := check_procedure_source(t, source, diagnostic_count = 0)
	testing.expect(t, ok)
}

@(test)
type_argument_to_any_is_rejected_with_typeid_suggestion :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
take :: proc(value: any) {}
main :: proc() {
	x := 1
	take(type_of(x))
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operand, "Cannot assign 'int', a type, to a procedure argument\n\tSuggestion: 'typeid_of(type_of(x))'")
	testing.expect(t, ok)
}

@(test)
type_valued_local_initializer_is_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
	x := 1
	t := type_of(x)
	_ = t
}
`)
	_, ok := check_procedure_source(
		t,
		source,
		.Invalid_Operand,
		"Cannot assign a type 'int' to variable 't'\n\tThe type of the variable 't' cannot be inferred as a type and does not have a default type",
	)
	testing.expect(t, ok)
}

@(test)
type_name_argument_to_type_parameter_reports_expected_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
print_name :: proc($T: typeid) {}
main :: proc() {
	print_name(typeid_of(int))
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operand, "Expected a type to assign to the type parameter")
	testing.expect(t, ok)
}

@(test)
type_argument_to_variadic_any_is_rejected_with_typeid_suggestion :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
take :: proc(values: ..any) {}
main :: proc() {
	take(int)
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operand, "Cannot assign 'int', a type, to a procedure argument\n\tSuggestion: 'typeid_of(int)'")
	testing.expect(t, ok)
}

@(test)
type_valued_assignment_source_is_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
	x := 1
	y := 2
	y = type_of(x)
	_ = y
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operand, "Cannot assign 'int', a type, to assignment")
	testing.expect(t, ok)
}

@(test)
type_valued_initializer_for_any_variable_is_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
	x: any = int
	_ = x
}
`)
	_, ok := check_procedure_source(t, source, .Invalid_Operand, "Cannot assign a type 'int' to variable 'x'", diagnostic_count = 1)
	testing.expect(t, ok)
}

@(test)
type_valued_return_to_any_is_rejected_with_official_notes :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() -> any {
	return int
}
`)
	_, ok := check_procedure_source(
		t,
		source,
		.Invalid_Operand,
		"Cannot assign 'int', a type, to return statement\n\tSuggestion: 'typeid_of(int)'\tSuggestion: If this is intended, make it explicit with a conversion to 'rawptr' or 'uintptr', or a 'transmute'",
		diagnostic_count = 1,
	)
	testing.expect(t, ok)
}

@(test)
type_valued_keyed_struct_field_is_rejected :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
S :: struct { f: any }
main :: proc() {
	s := S{f = int}
	_ = s
}
`)
	_, ok := check_procedure_source(
		t,
		source,
		.Invalid_Operand,
		"Cannot assign 'int', a type, to a structure literal\n\tSuggestion: 'typeid_of(int)'",
		diagnostic_count = 1,
	)
	testing.expect(t, ok)
}

@(test)
type_valued_positional_struct_field_is_ambiguous :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
S :: struct { f: any }
main :: proc() {
	s := S{int}
	_ = s
}
`)
	_, ok := check_procedure_source(
		t,
		source,
		.Invalid_Operand,
		"'int' is not an expression but a type, in this context it is ambiguous",
		diagnostic_count = 1,
	)
	testing.expect(t, ok)
}

@(test)
type_valued_fixed_array_element_is_ambiguous :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
	a := [1]any{int}
	_ = a
}
`)
	_, ok := check_procedure_source(
		t,
		source,
		.Invalid_Operand,
		"'int' is not an expression but a type, in this context it is ambiguous",
		diagnostic_count = 1,
	)
	testing.expect(t, ok)
}

@(test)
type_valued_slice_element_is_ambiguous :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
	s := []any{int}
	_ = s
}
`)
	_, ok := check_procedure_source(
		t,
		source,
		.Invalid_Operand,
		"'int' is not an expression but a type, in this context it is ambiguous",
		diagnostic_count = 1,
	)
	testing.expect(t, ok)
}

@(test)
type_valued_assignment_to_any_suggests_typeid :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() {
	x: any
	x = int
	_ = x
}
`)
	_, ok := check_procedure_source(
		t,
		source,
		.Invalid_Operand,
		"Cannot assign 'int', a type, to assignment\n\tSuggestion: 'typeid_of(int)'",
		diagnostic_count = 1,
	)
	testing.expect(t, ok)
}

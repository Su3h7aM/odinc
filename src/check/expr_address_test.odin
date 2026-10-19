package check

import "core:testing"

@(test)
address_of_composite_literal_is_addressable :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Info :: struct {writer: u8}
Error :: enum {Short_Buffer}
main :: proc "contextless" () {
	pointer := &Info{writer = 1}
	error := (Error).Short_Buffer
	#assert(Info{writer = 7}.writer == 7)
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
address_of_map_element_is_addressable :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	records: map[int]int
	pointer := &records[2]
	pointer^ = 4
}
`)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
address_of_optional_element_pairs_with_comma_ok :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
Shape :: union {u8}
main :: proc "contextless" () {
	records: map[int]int
	if record, found := &records[1]; found { record^ = 3 }
	shape: Shape
	if value, is_u8 := &shape.(u8); is_u8 { value^ = 2 }
}
`,
	)
	procedure, ok := check_procedure_source(t, valid, diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
address_of_type_assertion_follows_its_source :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
Shape :: union {u8}
main :: proc "contextless" () {
	shape: Shape
	pointer := &shape.(u8)
	pointer^ = 3
	shape_pointer := &shape
	through := &shape_pointer.(u8)
	value: any
	boxed := &value.(int)
}
`,
	)
	procedure, ok := check_procedure_source(t, valid, diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
	rejected, rejected_ok := check_procedure_source(
		t,
		transmute([]byte)string(
			`package sample
Shape :: union {u8}
make_shape :: proc "contextless" () -> Shape { return Shape(u8(1)) }
main :: proc "contextless" () { pointer := &make_shape().(u8) }
`,
		),
		.Unsupported,
		"Address_Mode",
	)
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}

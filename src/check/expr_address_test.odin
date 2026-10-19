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

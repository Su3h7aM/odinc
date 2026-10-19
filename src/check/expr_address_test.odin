package check

import "core:testing"

@(test)
address_of_composite_literal_is_addressable :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
Info :: struct {writer: u8}
main :: proc "contextless" () {
	pointer := &Info{writer = 1}
}
`)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

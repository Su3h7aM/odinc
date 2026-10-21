package check

import "core:testing"

@(test)
call_argument_rejects_broadcast_into_no_broadcast_parameter :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
take :: proc(#no_broadcast value: [2]u8) {}
main :: proc() {
	take(4)
}
`)
	_, ok := check_procedure_source(t, source, .Conversion, diagnostic_count = 1)
	testing.expect(t, ok)
}

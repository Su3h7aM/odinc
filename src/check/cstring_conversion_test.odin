package check

import "core:testing"

@(test)
cstring_constant_converts_to_string :: proc(t: ^testing.T) {
	// Official accepts `string(cstring("text"))` as a constant conversion.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	text := string(cstring("text"))
}
`)
	_, ok := check_procedure_source(t, source)
	testing.expect(t, ok)
}

@(test)
cstring_rejects_integer_cast :: proc(t: ^testing.T) {
	// Official: Cannot cast 'n' as 'cstring' from 'int'.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	n: int = 1
	text := cstring(n)
}
`)
	_, ok := check_procedure_source(t, source, .Conversion, "")
	testing.expect(t, ok)
}

@(test)
cstring_rejects_pointer_to_string_cast :: proc(t: ^testing.T) {
	// Official: Cannot cast 'p' as 'string' from '^int'.
	source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	p: ^int
	text := string(p)
}
`)
	_, ok := check_procedure_source(t, source, .Conversion, "")
	testing.expect(t, ok)
}

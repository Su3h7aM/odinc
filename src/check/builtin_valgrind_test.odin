package check

import "core:testing"

@(test)
valgrind_requests_require_seven_pointer_sized_integers :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
request :: proc(value: uintptr) -> uintptr { return valgrind_client_request(value, 1, 0, 0, 0, 0, 0) }
bad :: proc(value: u32) -> uintptr { return valgrind_client_request(value, 1, 0, 0, 0, 0, 0) }
`,
	)
	for name in ([?]string{"request", "bad"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name, intrinsic_names = []string{"valgrind_client_request"})
		if ok { testing.expect(t, (procedure.body_state == .Complete) == (name == "request")) }
	}
}

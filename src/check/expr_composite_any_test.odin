package check

import "core:testing"

@(test)
any_literal_accepts_data_and_typeid_fields :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
make_any :: proc(data: rawptr, id: typeid) -> any { return any{data, id} }
make_named :: proc(data: rawptr, id: typeid) -> any { return any{id = id, data = data} }
`,
	)
	for name in ([?]string{"make_any", "make_named"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name)
		if ok { testing.expect(t, procedure.body_state == .Complete) }
	}
}

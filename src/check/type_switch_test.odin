package check

import "core:testing"

@(test)
type_switch_checks_union_and_any_cases :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" (value: union { u8, bool, typeid }) {
	switch v in value {
	case u8:
	case bool:
	case typeid:
	}
	local := value
	switch &v in local {
	case u8:
	case bool:
	case typeid:
	}
	#partial switch v in value {
	case u8:
	}
	#partial switch v in value {
	case u8:
	case:
	}
}
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)

	invalid_sources := [?][]byte {
		transmute([]byte)string(`package sample
main :: proc "contextless" (value: union { u8, bool }) {
	switch v in value {
	case u8:
	}
}
`),
		transmute([]byte)string(`package sample
main :: proc "contextless" (value: union { u8 }) {
	switch v in value {
	case bool:
	case u8:
	}
}
`),
	}
	for source in invalid_sources {
		rejected, rejected_ok := check_procedure_source(t, source)
		if !rejected_ok { continue }
		testing.expect(t, rejected.body_state == .Invalid)
	}
}

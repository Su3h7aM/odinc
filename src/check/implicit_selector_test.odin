package check

import "core:testing"

@(test)
implicit_selector_resolves_union_variant_only_when_unique :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Mode :: enum u8 { None, Failed }
Other :: enum u8 { None }
Result :: union { Mode, Other }
unique :: proc "contextless" () -> Result { return .Failed }
ambiguous :: proc "contextless" () -> Result { return .None }
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "unique")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
	rejected, rejected_ok := check_procedure_source(t, source, procedure_name = "ambiguous")
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}

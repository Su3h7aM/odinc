package check

import "core:testing"

@(test)
assignments_expand_results_and_check_each_destination :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	first, second: u8
	first, second = pair()
	_, second = pair()
	_, _ = pair()
	first, second = second, first
	first, _, second = 3, pair()
}
pair :: proc "contextless" () -> (u8, u8) { return 1, 2 }
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
	invalid := []struct {
		source: string,
		kind:   Expression_Diagnostic_Kind,
		reason: string,
	} {
		{`package sample
main :: proc "contextless" () { first, second: u8; first, second = 1 }
`, .Unsupported, "Assign_Arity"},
		{
			`package sample
main :: proc "contextless" () { first, second: u8; first, second = pair() }
pair :: proc "contextless" () -> (u8, bool) { return 1, 1 < 2 }
`,
			.Conversion,
			"",
		},
	}
	for rejection in invalid {
		rejected, rejected_ok := check_procedure_source(t, transmute([]byte)rejection.source, rejection.kind, rejection.reason)
		if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
	}
}

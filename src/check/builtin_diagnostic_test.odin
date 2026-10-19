package check

import "core:testing"

@(test)
unsupported_intrinsic_reports_its_name :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
main :: proc() { objc_find_class(nil) }
`)
	procedure, ok := check_procedure_source(t, source, .Unsupported, "objc_find_class", intrinsic_names = []string{"objc_find_class"})
	if ok { testing.expect(t, procedure.body_state == .Invalid) }
}

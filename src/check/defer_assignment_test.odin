package check

import "core:testing"

@(test)
defer_rejects_only_singular_direct_named_result_assignments :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
direct :: proc() -> (result: int) {
    defer result = 9
    return 2
}
blocks :: proc() -> (result: int) {
    defer {{ result = 9 }}
    return 2
}
multiple :: proc() -> (a, b: int) {
    defer a, b = 9, 8
    return 2, 3
}
main :: proc() {}
`,
	)
	_, _ = check_procedure_source(t, source, .Unsupported, "Assign_Deferred_Result", diagnostic_count = 4)
}

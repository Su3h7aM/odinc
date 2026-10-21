package check

import "core:testing"

// Every result of a multi-result call converts to the type of the parameter it fills.
@(test)
tuple_spread_converts_each_result_to_the_parameter_type :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
pair :: proc() -> (int, int) { return 3, 4 }
mixed :: proc() -> (string, int) { return "s", 7 }
var_any :: proc(xs: ..any) -> int { return len(xs) }
two_any :: proc(x, y: any) {}
main :: proc() {
	_ = var_any(1, pair())
	_ = var_any(mixed())
	two_any(pair())
}
`,
	)
	procedure, ok := check_procedure_source(t, source)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

// A result that does not convert to the type of the parameter it fills is rejected, as official
// check_call_arguments_internal does.
@(test)
tuple_spread_rejects_results_that_do_not_convert :: proc(t: ^testing.T) {
	mismatch := transmute([]byte)string(
		`package sample
pair :: proc() -> (int, int) { return 3, 4 }
vsum :: proc(xs: ..f32) -> int { return len(xs) }
main :: proc() {
	_ = vsum(pair())
}
`,
	)
	rejected, rejected_ok := check_procedure_source(t, mismatch, .Unsupported, "Call_Tuple_Variadic_Type")
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
	extra := transmute([]byte)string(
		`package sample
triple :: proc() -> (int, int, int) { return 1, 2, 3 }
two_any :: proc(x, y: any) {}
main :: proc() {
	two_any(triple())
}
`,
	)
	rejected, rejected_ok = check_procedure_source(t, extra, .Unsupported, "Call_Arguments")
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}

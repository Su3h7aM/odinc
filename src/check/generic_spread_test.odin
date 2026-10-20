package check

import "core:testing"

@(test)
tuple_spread_accepts_group_and_variadic_callees :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
pair :: proc() -> (int, int) { return 3, 4 }
sum2 :: proc(a, b: int) -> int { return a + b }
sum3 :: proc(a, b, c: int) -> int { return a + b + c }
sumg :: proc{sum2, sum3}
vsum :: proc(xs: ..int) -> int { return 0 }
vmix :: proc(first: int, xs: ..int) -> int { return first }
main :: proc() {
	_ = sumg(pair())
	_ = sumg(pair(), 5)
	_ = vsum(pair())
	_ = vsum(pair(), 7)
	_ = vmix(pair())
	_ = vmix(1, pair())
}
`,
	)
	procedure, ok := check_procedure_source(t, source, .None, "", 0)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
}

@(test)
tuple_spread_rejects_extra_arguments_and_element_mismatch :: proc(t: ^testing.T) {
	extra := transmute([]byte)string(
		`package sample
pair :: proc() -> (int, int) { return 3, 4 }
sum2 :: proc(a, b: int) -> int { return a + b }
main :: proc() {
	_ = sum2(pair(), 5)
}
`,
	)
	rejected, rejected_ok := check_procedure_source(t, extra, .Unsupported, "Call_Arguments")
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
	mismatch := transmute([]byte)string(
		`package sample
pair :: proc() -> (int, int) { return 3, 4 }
vs :: proc(xs: ..string) -> int { return len(xs) }
main :: proc() {
	_ = vs(pair())
}
`,
	)
	rejected, rejected_ok = check_procedure_source(t, mismatch, .Unsupported, "Call_Tuple_Variadic_Type")
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}

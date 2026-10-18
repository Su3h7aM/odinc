package check

import "core:fmt"
import "core:testing"

@(test)
typed_operands_reject_no_value_calls_without_type_store_access :: proc(t: ^testing.T) {
	statements := []string{"_ = nothing()[0]", "_ = nothing().x", "_ = nothing()^", "_ = nothing()[:]", "for _ in nothing() {}", "nothing()()"}
	for statement in statements {
		source := fmt.aprintf("package sample\nnothing :: proc \"contextless\" () {{}}\nmain :: proc \"contextless\" () {{ %s }}", statement)
		_, ok := check_procedure_source(t, transmute([]byte)source, .Missing_Type, "expression has no type, mode No_Value", 1)
		testing.expectf(t, ok, "%s", source)
		delete(source)
	}
}

@(test)
range_calls_bind_leading_results_and_require_trailing_boolean :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
next :: proc "contextless" () -> (u8, int, bool) { return 1, 2, true }
main :: proc "contextless" () {
	for value in next() { byte: u8 = value }
	for value, index in next() { byte: u8 = value; position: int = index }
	for _, index in next() { position: int = index }
}
`,
	)
	procedure, ok := check_procedure_source(t, source, diagnostic_count = 0, procedure_name = "main")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
	_, rejected := check_procedure_source(
		t,
		transmute([]byte)string(
			`package sample
next :: proc "contextless" () -> (u8, int) { return 1, 2 }
main :: proc "contextless" () { for value in next() {} }
`,
		),
		.Invalid_Operand,
		"The final type of a multiple-valued expression must be a boolean",
		1,
	)
	testing.expect(t, rejected)
}

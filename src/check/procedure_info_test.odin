package check

import "core:testing"
import "oc:types"

@(test)
procedure_info_origin_and_checker_ownership :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	type_checker := Type_Checker {
		store = &store,
	}
	pool: Constant_Pool
	first, second: Expression_Checker
	if !testing.expect(t, expression_checker_init(&first, &type_checker, &pool, {}, 0, 0, context.allocator) == nil) { return }
	defer expression_checker_destroy(&first)
	if !testing.expect(t, expression_checker_init(&second, &type_checker, &pool, {}, 0, 0, context.allocator) == nil) { return }
	defer expression_checker_destroy(&second)
	origin := Procedure_Info_Origin {
		signature = {1, 2},
		scope     = 3,
		view      = 4,
	}
	defaults := []Default_Argument{{value = Operand(Const_Id(7))}}
	flags := []Entity_Flags{{.Any_Integer}}
	id, err := expression_procedure_info_intern(&first, origin, {defaults, flags})
	if !testing.expect(t, err == nil && id != 0) { return }
	defaults[0] = {}
	flags[0] = {}
	again, again_error := expression_procedure_info_intern(&first, origin, {})
	testing.expect(t, again_error == nil && again == id)
	info, lookup_error := expression_procedure_info(&first, id)
	if !testing.expect(t, lookup_error == .None && info != nil) { return }
	testing.expect(t, info.defaults[0].value == Operand(Const_Id(7)) && .Any_Integer in info.parameter_flags[0])
	for changed in ([]Procedure_Info_Origin{{signature = {1, 2}, scope = 5, view = 4}, {signature = {1, 2}, scope = 3, view = 6}, {signature = {1, 8}, scope = 3, view = 4}}) {
		other, other_error := expression_procedure_info_intern(&first, changed, {})
		testing.expect(t, other_error == nil && other != id)
	}
	second_id, second_error := expression_procedure_info_intern(&second, origin, {})
	testing.expect(t, second_error == nil && second_id != id)
	missing, missing_error := expression_procedure_info(&second, id)
	testing.expect(t, missing == nil && missing_error == .Invalid_Id)
	unowned, unowned_error := expression_procedure_info(&first, second_id)
	testing.expect(t, unowned == nil && unowned_error == .Invalid_Id)
	absent, absent_error := expression_procedure_info(&first, 0)
	testing.expect(t, absent == nil && absent_error == .None)
}

@(test)
static_procedure_calls_reject_invalid_arguments :: proc(t: ^testing.T) {
	cases := [?]struct {
		source: string,
		kind:   Expression_Diagnostic_Kind,
		reason: string,
	} {
		{
			`package sample
target :: proc(value: int) -> int { return value }
main :: proc() { callback := target; callback() }
`,
			.Unsupported,
			"Call_Default_Value",
		},
		{
			`package sample
target :: proc(value := 1) -> int { return value }
main :: proc() { callback := target; callback(other = 2) }
`,
			.Unsupported,
			"Call_Named_Parameter",
		},
		{
			`package sample
A :: distinct proc() -> int
B :: distinct proc() -> int
Value :: union { A, int }
main :: proc() { value: Value; _, _ = value.(B) }
`,
			.Mismatched_Types,
			"",
		},
		{
			`package sample
Value :: union { proc(value := 4) -> int, int }
main :: proc() {
	value: Value
	switch entry in value { case proc(different := 8) -> int: case int: }
}
`,
			.Invalid_Operand,
			"",
		},
	}
	for test in cases {
		procedure, ok := check_procedure_source(t, transmute([]byte)test.source, test.kind, test.reason)
		if !testing.expect(t, ok) { continue }
		testing.expect(t, procedure.body_state == .Invalid)
	}
}

package check

import "core:testing"

@(test)
generic_group_any_integer_accepts_typed_integer_arguments :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(
		`package sample
convert :: proc($T: typeid/[]$E, #any_int value: int) -> int { return value }
convert_group :: proc{convert}
main :: proc() -> int { value: u32 = 3; return convert_group([]byte, value) }
`,
	)
	procedure, ok := check_procedure_source(t, valid)
	if !ok { return }
	testing.expect(t, procedure.body_state == .Complete)
	// Official Odin: "Cannot assign value 'value' of type 'f32' to 'int' in a procedure argument".
	rejected, rejected_ok := check_procedure_source(
		t,
		transmute([]byte)string(
			`package sample
convert :: proc($T: typeid/[]$E, #any_int value: int) -> int { return value }
convert_group :: proc{convert}
main :: proc() -> int { value: f32 = 3; return convert_group([]byte, value) }
`,
		),
		.No_Matching_Overload,
	)
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}

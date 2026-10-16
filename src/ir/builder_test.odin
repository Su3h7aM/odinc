package ir

import "core:testing"

@(private = "file")
has_code :: proc(errors: []Verify_Error, code: Verify_Code) -> bool {
	for error in errors {
		if error.code == code {
			return true
		}
	}
	return false
}

// `add_or_zero(a, b: i64, c: bool) -> i64` of section 10, with the node ids printed there.
@(test)
builder_sample_verifies :: proc(t: ^testing.T) {
	fn, make_err := function_make(context.allocator, 0, "main.add_or_zero", 0)
	testing.expect_value(t, make_err, nil)
	defer function_destroy(fn)

	signature := add_signature(fn, Signature{cc = .C, params = {{type = .I64}, {type = .I64}, {type = .Bool, ext = .Zero}}, results = {{type = .I64}}})
	testing.expect_value(t, signature, fn.signature)

	entry := start(fn)
	true_head, false_head := if_(fn, entry.control, entry.params[2])
	sum := binary(fn, .Add, entry.params[0], entry.params[1])
	merge := region(fn, {true_head, false_head})
	zero := const_int(fn, .I64, 0)
	value := phi(fn, merge, {sum, zero})
	state := phi(fn, merge, {entry.memory, entry.memory})
	result := ret(fn, merge, state, value)
	testing.expect_value(t, function_finish(fn), nil)

	testing.expect_value(t, entry.params[2], Node_Id(6))
	testing.expect_value(t, sum, Node_Id(10))
	testing.expect_value(t, value, Node_Id(13))
	testing.expect_value(t, result, Node_Id(15))
	testing.expect_value(t, fn.stop, Node_Id(16))

	broken :: proc(t: ^testing.T, fn: ^Function, code: Verify_Code, label: string) {
		errors, err := verify(fn, context.allocator)
		defer delete(errors)
		testing.expect_value(t, err, nil)
		testing.expectf(t, has_code(errors, code), "%s: expected %v, got %v", label, code, errors)
	}

	set_input(fn, sum, 1, Node_Id(999))
	broken(t, fn, .Bad_Input_Id, "input out of range")
	set_input(fn, sum, 1, entry.params[1])

	set_input(fn, sum, 1, entry.params[2])
	broken(t, fn, .Bad_Type, "operand types differ")
	set_input(fn, sum, 1, entry.params[1])

	set_input(fn, value, 2, entry.params[2])
	broken(t, fn, .Bad_Type, "phi value type")
	set_input(fn, value, 2, zero)

	fn.nodes.data[entry.params[0]].index = 9
	broken(t, fn, .Bad_Projection, "projection index")
	fn.nodes.data[entry.params[0]].index = 2

	spare := add_node(fn, .Loop, .Control, {true_head, true_head})
	set_input(fn, spare, 0, spare)
	set_input(fn, spare, 1, spare)
	broken(t, fn, .Unreachable_Head, "unreachable head")
	remove_node(fn, spare)

	remove_node(fn, zero)
	broken(t, fn, .Removed_Node_Linked, "removed input")
}

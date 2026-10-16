package ir

import "core:testing"

@(private = "file")
new_function :: proc(t: ^testing.T, params: []Param) -> (^Function, Start_Nodes) {
	fn, err := function_make(context.allocator, 0, "case", 0)
	testing.expect_value(t, err, nil)
	add_signature(fn, Signature{cc = .C, params = params})
	return fn, start(fn)
}

// Finishes `fn` (which creates `Stop`) and checks that `verify` reports each code in
// `expected`, or nothing when it is empty.
@(private = "file")
expect_codes :: proc(t: ^testing.T, fn: ^Function, label: string, expected: ..Verify_Code) {
	_ = function_finish(fn)
	errors, err := verify(fn, context.allocator)
	defer delete(errors)
	testing.expect_value(t, err, nil)
	if len(expected) == 0 {
		testing.expectf(t, len(errors) == 0, "%s: unexpected %v", label, errors)
	}
	for code in expected {
		found := false
		for error in errors {
			found ||= error.code == code
		}
		testing.expectf(t, found, "%s: expected %v, got %v", label, code, errors)
	}
}

@(test)
verify_control_rejects_broken_graphs :: proc(t: ^testing.T) {
	{
		// C4: the "back edge" comes from a sibling arm the loop does not dominate.
		fn, entry := new_function(t, {{type = .Bool}})
		defer function_destroy(fn)
		arm, other := if_(fn, entry.control, entry.params[0])
		loop := add_node(fn, .Loop, .Control, {arm, other})
		state := phi(fn, loop, {entry.memory, entry.memory})
		ret(fn, loop, state)
		expect_codes(t, fn, "loop dominance", .Bad_Loop_Dominance)
	}
	{
		// C5: two regions that jump to each other and are entered from different arms.
		fn, entry := new_function(t, {{type = .Bool}})
		defer function_destroy(fn)
		arm, other := if_(fn, entry.control, entry.params[0])
		first := region(fn, {arm, arm})
		second := region(fn, {other, first})
		set_input(fn, first, 1, second)
		expect_codes(t, fn, "irreducible", .Irreducible)
	}
	{
		// C6: a loop without a memory phi.
		fn, entry := new_function(t, nil)
		defer function_destroy(fn)
		spin := add_node(fn, .Loop, .Control, {entry.control, NODE_NONE})
		set_input(fn, spin, 1, spin)
		expect_codes(t, fn, "loop without memory phi", .Bad_Phi)
	}
	{
		// D1: a value loaded in one arm is stored in the other.
		fn, entry := new_function(t, {{type = .Ptr}, {type = .Bool}})
		defer function_destroy(fn)
		pointer := entry.params[0]
		arm, other := if_(fn, entry.control, entry.params[1])
		value := load(fn, arm, entry.memory, pointer, .I64, 3)
		state := store(fn, other, entry.memory, pointer, value, 3)
		ret(fn, arm, entry.memory)
		ret(fn, other, state)
		expect_codes(t, fn, "value from a sibling block", .Unschedulable_Input)
	}
	{
		// D2: a pure node with a control input.
		fn, entry := new_function(t, nil)
		defer function_destroy(fn)
		add_node(fn, .Add, .I64, {const_int(fn, .I64, 1), entry.control})
		ret(fn, entry.control, entry.memory)
		expect_codes(t, fn, "pure node with control", .Bad_Control_Class)
	}
}

@(private = "file")
Diamonds :: enum {
	Correct,
	Stale_State,
	Missing_Phi,
}

// `if c1 { *p = 7 }` followed by `if c2 { *p = 7 }`. `Stale_State` makes the second diamond
// reuse the state from before the first; `Missing_Phi` forgets the second merge's memory phi.
@(private = "file")
build_diamonds :: proc(t: ^testing.T, mode: Diamonds) -> ^Function {
	fn, entry := new_function(t, {{type = .Ptr}, {type = .Bool}, {type = .Bool}})
	pointer := entry.params[0]
	value := const_int(fn, .I64, 7)

	first_arm, first_other := if_(fn, entry.control, entry.params[1])
	first_store := store(fn, first_arm, entry.memory, pointer, value, 3)
	first_merge := region(fn, {first_arm, first_other})
	first_state := phi(fn, first_merge, {first_store, entry.memory})

	second_arm, second_other := if_(fn, first_merge, entry.params[2])
	base := entry.memory if mode == .Stale_State else first_state
	second_store := store(fn, second_arm, base, pointer, value, 3)
	second_merge := region(fn, {second_arm, second_other})
	switch mode {
	case .Correct:
		ret(fn, second_merge, phi(fn, second_merge, {second_store, first_state}))
	case .Stale_State:
		ret(fn, second_merge, phi(fn, second_merge, {second_store, entry.memory}))
	case .Missing_Phi:
		ret(fn, second_merge, second_store)
	}
	return fn
}

@(test)
verify_memory_rejects_inconsistent_states :: proc(t: ^testing.T) {
	{
		fn := build_diamonds(t, .Correct)
		defer function_destroy(fn)
		expect_codes(t, fn, "sequential diamonds")
	}
	{
		fn := build_diamonds(t, .Stale_State)
		defer function_destroy(fn)
		expect_codes(t, fn, "sequential diamonds reusing the first state", .Bad_Block_Entry_State, .Bad_Block_Chain)
	}
	{
		fn := build_diamonds(t, .Missing_Phi)
		defer function_destroy(fn)
		expect_codes(t, fn, "merge without memory phi", .Bad_Block_Entry_State)
	}

	for stale in ([]bool{false, true}) {
		// A plain load in an arm must read the state the arm starts with.
		fn, entry := new_function(t, {{type = .Ptr}, {type = .Bool}})
		defer function_destroy(fn)
		pointer := entry.params[0]
		state := store(fn, entry.control, entry.memory, pointer, const_int(fn, .I64, 1), 3)
		arm, other := if_(fn, entry.control, entry.params[1])
		load(fn, arm, entry.memory if stale else state, pointer, .I64, 3)
		ret(fn, arm, state)
		ret(fn, other, state)
		if stale {
			expect_codes(t, fn, "stale load", .Stale_Load)
		} else {
			expect_codes(t, fn, "fresh load")
		}
	}

	for chained in ([]bool{true, false}) {
		// Two ordered loads whose values are unused: only the state edge orders them.
		fn, entry := new_function(t, {{type = .Ptr}})
		defer function_destroy(fn)
		pointer := entry.params[0]
		access := Node_Data {
			access = {order = .Volatile, value_type = .I64},
		}
		first := add_node(fn, .Load_Ordered, .Tuple, {entry.control, entry.memory, pointer}, access)
		first_state := add_node(fn, .Proj, .Memory, {first}, {index = 0})
		second_input := first_state if chained else entry.memory
		second := add_node(fn, .Load_Ordered, .Tuple, {entry.control, second_input, pointer}, access)
		second_state := add_node(fn, .Proj, .Memory, {second}, {index = 0})
		ret(fn, entry.control, second_state)
		if chained {
			expect_codes(t, fn, "ordered pair")
		} else {
			expect_codes(t, fn, "unordered pair", .Bad_Block_Chain)
		}
	}
}

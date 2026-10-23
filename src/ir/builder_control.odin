package ir

import "base:runtime"
import "core:slice"

// Control-flow construction for `lower` (section 5). The builder tracks the current control
// head (`NODE_NONE` while code is unreachable) and the current environment: one `Node_Id` per
// variable, with variable 0 holding the memory state. Every transfer is a jump to a target;
// `break`, labeled `break`/`continue`, `continue`, `fallthrough` and the fall-through at the
// end of a body are all `jump_to` with the target the source construct names. A target is
// sealed once: its exits become a `Region` and its phis come from comparing the environments
// the exits recorded. Loops are sealed by `loop_end`; `builder_finish` does not seal them and
// asserts that none is open.

Variable :: distinct u32

MEMORY_VARIABLE :: Variable(0)

Jump_Target_Id :: distinct u32

// A target covers the variables that existed when it was created.
Jump_Target :: struct {
	variable_count: u32,
	heads:          [dynamic]Node_Id,
	values:         [dynamic]Node_Id, // `variable_count` entries per head
	sealed:         bool,
}

// Never copy or move a `Builder`; use `builder_make`.
Builder :: struct {
	fn:           ^Function,
	control:      Node_Id,
	values:       [dynamic]Node_Id,
	targets:      [dynamic]Jump_Target,
	open_loops:   int,
	scratch:      runtime.Allocator,
	// Temp data must not outlive the builder: `builder_destroy` rewinds it. Destroy builders in reverse order of creation.
	scratch_mark: runtime.Arena_Temp,
	allocator:    runtime.Allocator,
}

// The arms of an `If` (0 true, 1 false) or a `Switch` (case k, then default), with the
// environment at the branch.
Branch_Point :: struct {
	heads:  []Node_Id,
	values: []Node_Id,
}

Loop_State :: struct {
	loop:      Node_Id,
	variables: []Variable,
	phis:      []Node_Id,
}

builder_make :: proc(allocator: runtime.Allocator, fn: ^Function, entry: Start_Nodes) -> (b: ^Builder, err: runtime.Allocator_Error) {
	b = new(Builder, allocator) or_return
	defer if err != nil {
		free(b, allocator)
		b = nil
	}
	b.fn = fn
	b.allocator = allocator
	b.scratch_mark = runtime.default_temp_allocator_temp_begin()
	b.scratch = context.temp_allocator
	defer if err != nil {
		runtime.default_temp_allocator_temp_end(b.scratch_mark)
	}

	function_grow_in(fn, b.scratch) or_return
	defer if err != nil {
		function_seal(fn)
	}
	b.values = make([dynamic]Node_Id, 0, 16, b.scratch) or_return
	b.targets = make([dynamic]Jump_Target, b.scratch) or_return
	append(&b.values, entry.memory) or_return
	b.control = entry.control
	return b, nil
}

builder_destroy :: proc(b: ^Builder) {
	function_seal(b.fn)
	runtime.default_temp_allocator_temp_end(b.scratch_mark)
	free(b, b.allocator)
}

// Finishes the function. Every loop must have been closed with `loop_end` and every target
// with exits sealed.
builder_finish :: proc(b: ^Builder) -> Error {
	assert(b.open_loops == 0, "loop_begin without loop_end")
	for target in b.targets {
		assert(target.sealed || len(target.heads) == 0, "jump target with exits was never sealed")
	}
	return function_finish(b.fn)
}

variable_declare :: proc(b: ^Builder, value: Node_Id) -> Variable {
	if b.fn.error != nil {
		return 0
	}
	if _, err := append(&b.values, value); err != nil {
		b.fn.error = err
		return 0
	}
	return Variable(len(b.values) - 1)
}

variable_get :: proc(b: ^Builder, variable: Variable) -> Node_Id {
	return b.values[variable]
}

variable_set :: proc(b: ^Builder, variable: Variable, value: Node_Id) {
	b.values[variable] = value
}

// Ends the scope of every variable declared after the first `count`.
variables_truncate :: proc(b: ^Builder, count: int) {
	assert(count >= 1 && count <= len(b.values))
	err := resize(&b.values, count)
	assert(err == nil)
}

jump_target_make :: proc(b: ^Builder) -> Jump_Target_Id {
	if b.fn.error != nil {
		return 0
	}
	scratch := b.scratch
	target := Jump_Target {
		variable_count = u32(len(b.values)),
	}
	target.heads.allocator = scratch
	target.values.allocator = scratch
	if _, err := append(&b.targets, target); err != nil {
		b.fn.error = err
		return 0
	}
	return Jump_Target_Id(len(b.targets) - 1)
}

// Ends the current block with an edge to `id`; control is unreachable afterwards. Does
// nothing while unreachable.
jump_to :: proc(b: ^Builder, id: Jump_Target_Id) {
	if b.fn.error != nil || b.control == NODE_NONE {
		return
	}
	target := &b.targets[id]
	count := int(target.variable_count)
	assert(!target.sealed && len(b.values) >= count)
	_, heads_err := append(&target.heads, b.control)
	_, values_err := append(&target.values, ..b.values[:count])
	if heads_err != nil || values_err != nil {
		b.fn.error = heads_err if heads_err != nil else values_err
		return
	}
	b.control = NODE_NONE
}

// Makes the exits of `id` the current control and environment: nothing for no exit, the exit
// itself for one, else a `Region` with a phi for each variable whose value differs between
// exits. Returns whether the code after the target is reachable. The current control must be
// unreachable: every path into the target has to be a `jump_to`.
seal_target :: proc(b: ^Builder, id: Jump_Target_Id) -> (reachable: bool) {
	if b.fn.error != nil {
		return false
	}
	assert(b.control == NODE_NONE, "paths still open at seal_target")
	target := &b.targets[id]
	assert(!target.sealed)
	target.sealed = true

	exit_count := len(target.heads)
	count := int(target.variable_count)
	if exit_count == 0 {
		return false
	}
	if err := resize(&b.values, count); err != nil {
		b.fn.error = err
		return false
	}
	if exit_count == 1 {
		copy(b.values[:], target.values[:count])
		b.control = target.heads[0]
		return true
	}

	merge := region(b.fn, target.heads[:])
	inputs, err := make([]Node_Id, 1 + exit_count, b.scratch)
	if err != nil {
		b.fn.error = err
		return false
	}
	inputs[0] = merge
	for variable in 0 ..< count {
		first := target.values[variable]
		differs := false
		for exit in 1 ..< exit_count {
			differs ||= target.values[exit * count + variable] != first
		}
		if !differs {
			b.values[variable] = first
			continue
		}
		type := Value_Type.None
		for exit in 0 ..< exit_count {
			value := target.values[exit * count + variable]
			inputs[1 + exit] = value
			if type == .None {
				type = b.fn.nodes.type[value]
			}
		}
		b.values[variable] = add_node(b.fn, .Phi, type, inputs)
	}
	b.control = merge
	return true
}

// Ends the current block with an `If`. Call `enter_arm` to continue in an arm.
branch_if :: proc(b: ^Builder, condition: Node_Id) -> Branch_Point {
	if b.fn.error != nil {
		return {}
	}
	assert(b.control != NODE_NONE)
	true_head, false_head := if_(b.fn, b.control, condition)
	return branch_point_make(b, {true_head, false_head})
}

// Ends the current block with a `Switch` over `cases`; arm `len(cases)` is the default.
branch_switch :: proc(b: ^Builder, value: Node_Id, cases: []i64) -> Branch_Point {
	if b.fn.error != nil {
		return {}
	}
	assert(b.control != NODE_NONE)
	table, table_ok := add_table(b.fn, cases)
	if !table_ok {
		return {}
	}
	split := add_node(b.fn, .Switch, .Tuple, {b.control, value}, {index = table})
	heads, err := make([]Node_Id, len(cases) + 1, b.scratch)
	if err != nil {
		b.fn.error = err
		return {}
	}
	for &head, arm in heads {
		head = add_node(b.fn, .Proj, .Control, {split}, {index = u32(arm)})
	}
	return branch_point_make(b, heads)
}

// Continues in one arm, with the environment the branch saw; variables declared since are
// dropped.
enter_arm :: proc(b: ^Builder, point: Branch_Point, arm: int) {
	if b.fn.error != nil {
		return
	}
	b.control = point.heads[arm]
	if err := resize(&b.values, len(point.values)); err != nil {
		b.fn.error = err
		return
	}
	copy(b.values[:], point.values)
}

// Creates the `Loop`, makes it the current control, and replaces the memory variable and each
// variable in `assigned` (the pre-scan of the body) by a phi that `loop_end` completes.
loop_begin :: proc(b: ^Builder, assigned: []Variable) -> Loop_State {
	if b.fn.error != nil {
		return {}
	}
	assert(b.control != NODE_NONE)
	scratch := b.scratch
	variables, variables_err := make([]Variable, 1 + len(assigned), scratch)
	phis, phis_err := make([]Node_Id, 1 + len(assigned), scratch)
	if variables_err != nil || phis_err != nil {
		b.fn.error = variables_err if variables_err != nil else phis_err
		return {}
	}
	variables[0] = MEMORY_VARIABLE
	copy(variables[1:], assigned)

	loop := add_node(b.fn, .Loop, .Control, {b.control, NODE_NONE})
	for variable, index in variables {
		assert(index == 0 || variable != MEMORY_VARIABLE)
		phis[index] = phi(b.fn, loop, {b.values[variable], NODE_NONE})
		b.values[variable] = phis[index]
	}
	b.control = loop
	b.open_loops += 1
	return {loop = loop, variables = variables, phis = phis}
}

// Closes the loop with the current control as its back edge and the current environment as
// the back values of its phis. Without a reachable back edge the loop is collapsed instead.
// Control is unreachable afterwards: code after a loop starts at the target its exits sealed.
loop_end :: proc(b: ^Builder, state: Loop_State) {
	if b.fn.error != nil {
		return
	}
	b.open_loops -= 1
	if b.control == NODE_NONE {
		loop_collapse(b, state)
		return
	}
	set_input(b.fn, state.loop, 1, b.control)
	for variable, index in state.variables {
		set_input(b.fn, state.phis[index], 2, b.values[variable])
	}
	b.control = NODE_NONE
}

// Replaces the header by its entry head and each phi by its entry value, everywhere: in the
// graph and in the exits recorded by pending targets. The substitution rewrites inputs of
// interned nodes, so the table is rebuilt afterwards.
@(private = "file")
loop_collapse :: proc(b: ^Builder, state: Loop_State) {
	fn := b.fn
	replacement, err := make([]Node_Id, len(fn.nodes), b.scratch)
	if err != nil {
		fn.error = err
		return
	}
	replacement[state.loop] = node_input(fn, state.loop, 0)
	for phi_node in state.phis {
		replacement[phi_node] = node_input(fn, phi_node, 1)
	}

	substitute :: proc(replacement: []Node_Id, ids: []Node_Id) {
		for &id in ids {
			if replacement[id] != NODE_NONE {
				id = replacement[id]
			}
		}
	}
	substitute(replacement, fn.edges[:])
	substitute(replacement, b.values[:])
	for &target in b.targets {
		substitute(replacement, target.heads[:])
		substitute(replacement, target.values[:])
	}
	for phi_node in state.phis {
		remove_node(fn, phi_node)
	}
	remove_node(fn, state.loop)
	intern_rebuild(fn)
}

emit_return :: proc(b: ^Builder, results: ..Node_Id) {
	if b.fn.error == nil && b.control != NODE_NONE {
		ret(b.fn, b.control, b.values[MEMORY_VARIABLE], ..results)
		b.control = NODE_NONE
	}
}

emit_trap :: proc(b: ^Builder) {
	if b.fn.error == nil && b.control != NODE_NONE {
		trap(b.fn, b.control, b.values[MEMORY_VARIABLE])
		b.control = NODE_NONE
	}
}

emit_unreachable :: proc(b: ^Builder) {
	if b.fn.error == nil && b.control != NODE_NONE {
		unreachable(b.fn, b.control, b.values[MEMORY_VARIABLE])
		b.control = NODE_NONE
	}
}

@(private = "file")
branch_point_make :: proc(b: ^Builder, heads: []Node_Id) -> Branch_Point {
	scratch := b.scratch
	cloned_heads, heads_err := slice.clone(heads, scratch)
	values, values_err := slice.clone(b.values[:], scratch)
	if heads_err != nil || values_err != nil {
		b.fn.error = heads_err if heads_err != nil else values_err
		return {}
	}
	b.control = NODE_NONE
	return {heads = cloned_heads, values = values}
}

package regalloc

import "core:testing"

@(private = "file")
use :: proc(vreg: Vreg) -> Operand {
	return Operand{vreg = vreg, role = .Use, position = .Early}
}

@(private = "file")
def :: proc(vreg: Vreg) -> Operand {
	return Operand{vreg = vreg, role = .Def, position = .Late}
}

@(private = "file")
fixed_to :: proc(operand: Operand, register: Register) -> Operand {
	result := operand
	result.constraint = .Fixed
	result.fixed = register
	return result
}

@(private = "file")
expect_allocation_verifies :: proc(t: ^testing.T, program: ^Program) -> (result: Result, ok: bool) {
	err: Error
	result, err = allocate(program)
	testing.expect_value(t, err.kind, Allocation_Error.None)
	if err.kind != .None {
		return
	}
	verify_err := verify(program, &result)
	testing.expect_value(t, verify_err.kind, Allocation_Error.None)
	return result, verify_err.kind == .None
}

@(test)
spills_the_cheapest_values_under_pressure :: proc(t: ^testing.T) {
	instructions := []Instruction {
		{operands = {def(0)}},
		{operands = {def(1)}},
		{operands = {def(2)}},
		{operands = {def(3)}},
		{operands = {use(0)}},
		{operands = {use(0)}},
		{operands = {use(0)}},
		{operands = {use(0), use(1), use(2), use(3)}},
	}
	classes := make([]Register_Class, 4)
	defer delete(classes)
	program := Program {
		blocks = {{instructions = instructions}},
		classes = classes,
		allocatable = #partial{.Int = {0, 1}},
	}
	result, ok := expect_allocation_verifies(t, &program)
	if !ok {
		return
	}
	defer result_destroy(&result)
	testing.expect_value(t, result.spill_slot_count, 2)
	_, hot_in_register := result.location[0].(Register)
	testing.expect(t, hot_in_register)
}

@(test)
keeps_loop_values_across_a_call_in_callee_saved_registers :: proc(t: ^testing.T) {
	call_clobbers := #partial [Register_Class]Register_Set {
		.Int = {0, 1, 2},
	}
	entry := []Instruction{{operands = {def(0)}}, {operands = {def(1)}}}
	body := []Instruction {
		{operands = {def(2)}},
		{operands = {def(3)}},
		{operands = {use(3)}},
		{clobbers = call_clobbers, is_call = true},
		{operands = {Operand{vreg = 0, role = .Use_Def, position = .Early}, use(2)}},
		{operands = {use(1)}},
	}
	exit := []Instruction{{operands = {use(0)}}}
	classes := make([]Register_Class, 4)
	defer delete(classes)
	program := Program {
		blocks = {{instructions = entry, successors = {1}}, {instructions = body, successors = {1, 2}, depth = 1}, {instructions = exit}},
		classes = classes,
		allocatable = #partial{.Int = {0, 1, 2, 3, 4, 5}},
		callee_saved = #partial{.Int = {3, 4, 5}},
	}
	result, ok := expect_allocation_verifies(t, &program)
	if !ok {
		return
	}
	defer result_destroy(&result)
	for across_call in 0 ..< 3 {
		register, is_register := result.location[across_call].(Register)
		testing.expect(t, is_register && int(register) in program.callee_saved[.Int])
	}
	short_lived, is_register := result.location[3].(Register)
	testing.expect(t, is_register && int(short_lived) in Register_Set{0, 1, 2})
	testing.expect_value(t, result.callee_saved_used[.Int], Register_Set{3, 4, 5})
}

@(test)
honors_fixed_registers_and_reuse_input :: proc(t: ^testing.T) {
	RAX :: Register(0)
	RCX :: Register(1)
	RDX :: Register(2)
	division_clobbers := #partial [Register_Class]Register_Set {
		.Int = {0, 2},
	}
	shift := Operand {
		vreg       = 4,
		role       = .Def,
		position   = .Late,
		constraint = .Reuse_Input,
		reuse      = 1,
	}
	instructions := []Instruction {
		{operands = {def(0)}},
		{operands = {def(1)}},
		{operands = {def(2)}},
		{operands = {use(2), fixed_to(def(3), RCX)}, is_move = true},
		{operands = {shift, use(0), fixed_to(use(3), RCX)}},
		{operands = {use(4), fixed_to(def(5), RAX)}, is_move = true},
		{operands = {fixed_to(Operand{vreg = 5, role = .Use_Def, position = .Early}, RAX), use(1), fixed_to(def(6), RDX)}, clobbers = division_clobbers},
		{operands = {use(0), use(5), use(6)}},
	}
	classes := make([]Register_Class, 7)
	defer delete(classes)
	program := Program {
		blocks = {{instructions = instructions}},
		classes = classes,
		allocatable = #partial{.Int = {0, 1, 2, 3, 4, 5}},
	}
	result, ok := expect_allocation_verifies(t, &program)
	if !ok {
		return
	}
	defer result_destroy(&result)
	testing.expect_value(t, result.location[3], Location(RCX))
	testing.expect_value(t, result.location[5], Location(RAX))
	testing.expect_value(t, result.location[6], Location(RDX))
	testing.expect_value(t, len(result.inserted_moves), 1)
	if len(result.inserted_moves) == 1 {
		testing.expect_value(t, result.inserted_moves[0].move, Move{source = 0, destination = 4})
	}
}

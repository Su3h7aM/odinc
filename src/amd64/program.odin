package amd64

import "base:runtime"
import "core:mem"
import "oc:regalloc"

// Builds the allocator's view of `function`. The blocks, instructions and operand
// lists are allocated with `allocator` and the classes slice borrows from `function`,
// so both must outlive the allocation; free the former with an arena. `function`
// must pass `verify_machine`.
build_program :: proc(function: ^Machine_Function, allocator: mem.Allocator) -> (program: regalloc.Program, err: runtime.Allocator_Error) {
	blocks := make([]regalloc.Block, len(function.blocks), allocator) or_return
	for block, block_index in function.blocks {
		instructions := make([]regalloc.Instruction, len(block.instructions), allocator) or_return
		for instruction, instruction_index in block.instructions {
			instructions[instruction_index] = translate_instruction(instruction, allocator) or_return
		}
		successors := make([]u32, len(block.successors), allocator) or_return
		copy(successors, block.successors[:])
		blocks[block_index] = regalloc.Block {
			instructions = instructions,
			successors   = successors,
			edge_moves   = make([][]regalloc.Move, len(successors), allocator) or_return,
			depth        = block.depth,
		}
		for moves, edge in block.edge_moves {
			stored := make([]regalloc.Move, len(moves), allocator) or_return
			copy(stored, moves)
			blocks[block_index].edge_moves[edge] = stored
		}
	}
	program.blocks = blocks
	program.classes = function.vreg_classes[:]
	program.allocatable = {
		.Int   = INT_ALLOCATABLE,
		.Float = FLOAT_ALLOCATABLE,
	}
	program.callee_saved = #partial {
		.Int = INT_CALLEE_SAVED,
	}
	program.scratch = {
		.Int   = INT_SCRATCH,
		.Float = FLOAT_SCRATCH,
	}
	return program, nil
}

@(private = "file")
translate_instruction :: proc(instruction: Machine_Instruction, allocator: mem.Allocator) -> (result: regalloc.Instruction, err: runtime.Allocator_Error) {
	info, _ := op_info(instruction.mnemonic)
	operands := make([dynamic]regalloc.Operand, 0, len(instruction.operands), allocator) or_return
	for operand, index in instruction.operands {
		switch value in operand {
		case Vreg:
			access := pseudo_access(instruction.pseudo, index) if instruction.pseudo != .None else info.access[index]
			if access == .Def {
				reuse := u8(0)
				constraint := regalloc.Constraint.Any
				if index == 0 && reuses_first_input(instruction, info) {
					constraint = .Reuse_Input
					reuse = 1
				}
				append(&operands, regalloc.Operand{vreg = value, role = .Def, position = .Late, constraint = constraint, reuse = reuse}) or_return
			} else {
				append(&operands, regalloc.Operand{vreg = value, role = .Use, position = .Early}) or_return
			}
		case Fixed_Vreg:
			position := regalloc.Position.Late if value.role == .Def else .Early
			append(
				&operands,
				regalloc.Operand{vreg = value.vreg, role = value.role, position = position, constraint = .Fixed, fixed = value.register},
			) or_return
		case Memory_Ref:
			if base, is_vreg := value.base.(Vreg); is_vreg {
				append(&operands, regalloc.Operand{vreg = base, role = .Use, position = .Early}) or_return
			}
			if value.has_index {
				append(&operands, regalloc.Operand{vreg = value.index, role = .Use, position = .Early}) or_return
			}
		case Immediate, Block_Ref, Symbol_Target, Thread_Pointer_Offset, Physical_Register:
		}
	}
	result = regalloc.Instruction {
		operands = operands[:],
		clobbers = instruction.clobbers,
		is_call  = instruction.pseudo == .Call,
		is_move  = instruction.pseudo == .Copy,
	}
	return result, nil
}

// A two-address instruction runs as `dst = src1; op dst, src2` unless `reuse_unless_immediate`
// applies and its last operand is an immediate.
reuses_first_input :: proc(instruction: Machine_Instruction, info: Op_Info) -> bool {
	if !info.two_address || len(instruction.operands) == 0 {
		return false
	}
	return !(info.reuse_unless_immediate && is_immediate(instruction.operands[len(instruction.operands) - 1]))
}

// Access of a plain virtual register operand of a pseudo instruction.
pseudo_access :: proc(pseudo: Pseudo, index: int) -> Op_Access {
	switch pseudo {
	case .Copy:
		return .Def if index == 0 else .Use
	case .Call:
		return .Use if index == 0 else .None
	case .Syscall:
		return .Use
	case .None, .Entry, .Return:
	}
	return .None
}

@(private = "file")
is_immediate :: proc(operand: Machine_Operand) -> bool {
	_, ok := operand.(Immediate)
	return ok
}

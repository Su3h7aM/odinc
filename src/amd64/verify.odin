package amd64

Verify_Kind :: enum u8 {
	None,
	Empty_Block,
	Bad_Successor,
	Misplaced_Terminator,
	Missing_Terminator,
	Unknown_Mnemonic,
	Bad_Vreg,
	Bad_Fixed_Register,
	Bad_Block_Ref,
	Bad_Operand,
	Flags_Not_Set,
	Rip_With_Immediate,
}

Verify_Error :: struct {
	kind:        Verify_Kind,
	block:       u32,
	instruction: u32,
}

// Returns the first violation of the machine-code rules, or a zero `kind`: successors
// in range; each block ends in `JMP`, `UD2` or a `Return` pseudo, with only
// conditional jumps before it; vregs and block references exist; fixed registers are
// allocatable in the vreg's class; operands match `op_info` (a two-address form has a
// vreg as operand 1); a flags reader follows a flags writer in its block with no call
// between; no RIP-relative operand shares an instruction with an immediate.
verify_machine :: proc(function: ^Machine_Function) -> Verify_Error {
	for block, block_index in function.blocks {
		bi := u32(block_index)
		if len(block.instructions) == 0 {
			return {.Empty_Block, bi, 0}
		}
		for successor in block.successors {
			if int(successor) >= len(function.blocks) {
				return {.Bad_Successor, bi, 0}
			}
		}
		flags_valid := false
		branching := false
		for instruction, instruction_index in block.instructions {
			ii := u32(instruction_index)
			info, known := instruction_info(instruction)
			if instruction.pseudo == .None && !known {
				return {.Unknown_Mnemonic, bi, ii}
			}
			ends_block := info.terminator || instruction.pseudo == .Return
			if ends_block && instruction_index != len(block.instructions) - 1 {
				return {.Misplaced_Terminator, bi, ii}
			}
			if branching && !info.branch && !ends_block {
				return {.Misplaced_Terminator, bi, ii}
			}
			branching ||= info.branch
			if kind := verify_operands(function, instruction, info); kind != .None {
				return {kind, bi, ii}
			}
			if info.reads_flags && !flags_valid {
				return {.Flags_Not_Set, bi, ii}
			}
			if info.writes_flags {
				flags_valid = true
			}
			if instruction.pseudo == .Call || instruction.pseudo == .Client_Request || instruction.mnemonic == .SYSCALL {
				flags_valid = false
			}
		}
		last := block.instructions[len(block.instructions) - 1]
		last_info, _ := op_info(last.mnemonic)
		if !last_info.terminator && last.pseudo != .Return {
			return {.Missing_Terminator, bi, u32(len(block.instructions) - 1)}
		}
	}
	return {}
}

@(private = "file")
verify_operands :: proc(function: ^Machine_Function, instruction: Machine_Instruction, info: Op_Info) -> Verify_Kind {
	has_rip, has_immediate := false, false
	for operand, index in instruction.operands {
		switch value in operand {
		case Vreg:
			if int(value) >= len(function.vreg_classes) {
				return .Bad_Vreg
			}
			if instruction.pseudo == .None && index >= int(instruction.explicit_count) {
				return .Bad_Operand
			}
		case Physical_Register:
			if Gpr(value) != .RSP {
				return .Bad_Fixed_Register
			}
		case Fixed_Vreg:
			if int(value.vreg) >= len(function.vreg_classes) {
				return .Bad_Vreg
			}
			if int(value.register) not_in allocatable_registers(function.vreg_classes[value.vreg]) {
				return .Bad_Fixed_Register
			}
		case Memory_Ref:
			if base, is_vreg := value.base.(Vreg); is_vreg && int(base) >= len(function.vreg_classes) {
				return .Bad_Vreg
			}
			if value.has_index && int(value.index) >= len(function.vreg_classes) {
				return .Bad_Vreg
			}
			if _, is_symbol := value.base.(Symbol_Target); is_symbol {
				has_rip = true
			}
		case Block_Ref:
			if int(value) >= len(function.blocks) {
				return .Bad_Block_Ref
			}
		case Immediate:
			has_immediate = true
		case Symbol_Target, Thread_Pointer_Offset:
		}
	}
	if has_rip && has_immediate {
		return .Rip_With_Immediate
	}
	if info.two_address && instruction.pseudo == .None {
		if len(instruction.operands) < 2 {
			return .Bad_Operand
		}
		if _, ok := instruction.operands[1].(Vreg); !ok {
			return .Bad_Operand
		}
	}
	return .None
}

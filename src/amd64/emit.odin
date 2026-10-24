package amd64

import "base:runtime"
import "core:mem"
import x86 "core:rexcode/isa/x86"
import "oc:elf"
import "oc:ir"
import "oc:link"
import "oc:regalloc"

// rexcode's Instruction_Flags.segment index for FS.
FS_SEGMENT_INDEX :: u8(5)

Emit_Failure :: enum u8 {
	None,
	// Encoding_Failed: the encoder rejected an instruction; the machine function was not valid for emission.
	Encoding_Failed,
	// Scratch_Exhausted: one instruction needs more than two spilled registers of one class at once.
	Scratch_Exhausted,
	Bad_Operand,
	Missing_Location,
	Unknown_Symbol,
	Unsupported_Alignment,
}

Emit_Error :: union #shared_nil {
	Emit_Failure,
	runtime.Allocator_Error,
}

// Symbol_Indices maps an `ir.Symbol_Ref` to the index of its `link.Symbol`, per space.
Symbol_Indices :: [ir.Symbol_Space][]u32

INT_SCRATCH_REGISTERS :: [2]u8{u8(Gpr.R10), u8(Gpr.R11)}
FLOAT_SCRATCH_REGISTERS :: [2]u8{14, 15}

@(private = "file")
External_Reference :: struct {
	symbol: u32,
	kind:   elf.R_X86_64,
	addend: i64,
}

@(private = "file")
Branch :: struct {
	instruction: u32,
	block:       u32,
	mnemonic:    x86.Mnemonic,
}

@(private = "file")
Pending_Store :: struct {
	class:  Register_Class,
	number: u8,
	slot:   regalloc.Spill_Slot,
}

@(private = "file")
Emitter :: struct {
	function:            ^Machine_Function,
	result:              ^regalloc.Result,
	layout:              Frame_Layout,
	symbols:             Symbol_Indices,
	instructions:        [dynamic]x86.Instruction,
	block_first:         []u32,
	externals:           [dynamic]External_Reference,
	branches:            [dynamic]Branch,
	local_branches:      [dynamic]Branch,
	scratch_taken:       [Register_Class]int,
	stores:              [4]Pending_Store,
	store_count:         int,
	epilogue_first:      u32,
	has_return:          bool,
	instruction_offsets: []u32,
}

// Emits `function` as one text atom. `result` is the allocation of `build_program(function)`.
// Branches start short and only ever grow to the long form, so relaxation terminates.
// References to other symbols come back as relocations whose `symbol` is looked up in
// `symbols`. The function's own `link.Symbol` is the caller's to add. Free with `atom_destroy`.
//
// Operand conventions the selector must follow: `MOVZX` and `MOVSX` write a 32-bit
// register and read `width` bytes, `MOVSXD` writes 64 bits and reads 32, a shift count in a
// register is `cl`, and a memory operand is `width` bytes wide.
emit_function :: proc(
	function: ^Machine_Function,
	result: ^regalloc.Result,
	symbols: Symbol_Indices,
	allocator: mem.Allocator,
) -> (
	atom: link.Atom,
	err: Emit_Error,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	context.allocator = context.temp_allocator

	emitter := Emitter {
		function = function,
		result   = result,
		symbols  = symbols,
	}
	emitter.layout = frame_layout(function, result, context.allocator) or_return
	emitter.block_first = make([]u32, len(function.blocks)) or_return
	emit_prologue(&emitter.instructions, emitter.layout) or_return

	move_cursor := 0
	copy_cursor := 0
	for block, block_index in function.blocks {
		emitter.block_first[block_index] = u32(len(emitter.instructions))
		for instruction, instruction_index in block.instructions {
			for copy_cursor < len(result.edge_copies) {
				edge := result.edge_copies[copy_cursor]
				if edge.block != u32(block_index) || edge.before != u32(instruction_index) {
					break
				}
				emit_location_move(&emitter, edge.class, edge.source, edge.destination) or_return
				copy_cursor += 1
			}
			for move_cursor < len(result.inserted_moves) {
				inserted := result.inserted_moves[move_cursor]
				if inserted.block != u32(block_index) || inserted.before != u32(instruction_index) {
					break
				}
				emit_vreg_move(&emitter, inserted.move.source, inserted.move.destination) or_return
				move_cursor += 1
			}
			emit_instruction_body(&emitter, instruction, u32(block_index)) or_return
		}
	}

	if emitter.has_return {
		drop_final_return_jump(&emitter)
		emitter.epilogue_first = u32(len(emitter.instructions))
		emit_epilogue(&emitter.instructions, emitter.layout) or_return
	}
	code, unresolved := relax_and_encode(&emitter) or_return
	bytes := make([]byte, len(code), allocator) or_return
	copy(bytes, code)
	relocations, alloc_err := make([]link.Relocation, len(unresolved), allocator)
	if alloc_err != nil {
		delete(bytes, allocator)
		return {}, alloc_err
	}
	for relocation, index in unresolved {
		external := emitter.externals[int(relocation.label_id) - external_base(function)]
		relocations[index] = link.Relocation {
			offset = relocation.offset,
			symbol = external.symbol,
			kind   = external.kind,
			addend = external.addend,
		}
	}
	unwind, unwind_err := emit_frame_unwind(emitter.layout, emitter.instruction_offsets, emitter.has_return, allocator)
	if unwind_err != nil {
		delete(bytes, allocator)
		delete(relocations, allocator)
		return {}, unwind_err
	}
	return link.Atom{section = .Text, align = 16, bytes = bytes, size = u64(len(bytes)), relocs = relocations, unwind = unwind}, nil
}

atom_destroy :: proc(atom: ^link.Atom, allocator: mem.Allocator) {
	delete(atom.bytes, allocator)
	delete(atom.relocs, allocator)
	delete(atom.unwind, allocator)
	atom^ = {}
}

@(private = "file")
relax_and_encode :: proc(emitter: ^Emitter) -> (code: []byte, unresolved: []x86.Relocation, err: Emit_Error) {
	instruction_count := len(emitter.instructions)
	instruction_label_base := external_base(emitter.function) + len(emitter.externals)
	for branch in emitter.local_branches {
		emitter.instructions[branch.instruction] = x86.inst_rel(branch.mnemonic, u32(instruction_label_base) + branch.block, 1)
	}
	label_defs := make([]x86.Label_Definition, instruction_label_base + instruction_count) or_return
	buffer := make([]byte, (instruction_count + 1) * x86.MAX_INST_SIZE) or_return
	relocations := make([dynamic]x86.Relocation) or_return
	errors := make([dynamic]x86.Error) or_return

	fill_labels :: proc(emitter: ^Emitter, label_defs: []x86.Label_Definition, instruction_label_base: int) {
		for first, block_index in emitter.block_first {
			label_defs[block_index] = x86.Label_Definition(first)
		}
		label_defs[epilogue_label(emitter.function)] = x86.Label_Definition(emitter.epilogue_first)
		for index in external_base(emitter.function) ..< instruction_label_base {
			label_defs[index] = x86.LABEL_UNDEFINED
		}
		for index in 0 ..< len(emitter.instructions) {
			label_defs[instruction_label_base + index] = x86.Label_Definition(index)
		}
	}

	for {
		fill_labels(emitter, label_defs, instruction_label_base)
		clear(&relocations)
		byte_count, ok := x86.encode(emitter.instructions[:], label_defs, buffer, &relocations, &errors, resolve = false)
		if !ok || len(errors) > 0 {
			return nil, nil, Emit_Failure.Encoding_Failed
		}
		grew := false
		for &branch in emitter.branches {
			if emitter.instructions[branch.instruction].ops[0].size == 4 {
				continue
			}
			end := byte_count
			if int(branch.instruction) + 1 < instruction_count {
				end = u32(label_defs[instruction_label_base + int(branch.instruction) + 1])
			}
			delta := i64(label_defs[branch.block]) - i64(end)
			if delta < -128 || delta > 127 {
				emitter.instructions[branch.instruction] = x86.inst_rel(branch.mnemonic, branch.block, 4)
				grew = true
			}
		}
		if !grew {
			break
		}
	}

	fill_labels(emitter, label_defs, instruction_label_base)
	clear(&relocations)
	byte_count, ok := x86.encode(emitter.instructions[:], label_defs, buffer, &relocations, &errors)
	if !ok || len(errors) > 0 {
		return nil, nil, Emit_Failure.Encoding_Failed
	}
	emitter.instruction_offsets = make([]u32, instruction_count + 1) or_return
	for index in 0 ..< instruction_count {
		emitter.instruction_offsets[index] = u32(label_defs[instruction_label_base + index])
	}
	emitter.instruction_offsets[instruction_count] = byte_count
	return buffer[:byte_count], relocations[:], nil
}

@(private = "file")
emit_instruction_body :: proc(emitter: ^Emitter, instruction: Machine_Instruction, block: u32) -> Emit_Error {
	switch instruction.pseudo {
	case .Entry:
		return nil
	case .Return:
		return emit_return_jump(emitter)
	case .Copy:
		destination, destination_ok := instruction.operands[0].(Vreg)
		source, source_ok := instruction.operands[1].(Vreg)
		if !destination_ok || !source_ok {
			return Emit_Failure.Bad_Operand
		}
		return emit_vreg_move(emitter, source, destination)
	case .Syscall:
		emitter.scratch_taken = {}
		emitter.store_count = 0
		for operand in instruction.operands {
			if value, ok := operand.(Vreg); ok {
				source := vreg_register(emitter, value, Access{reads = true}, 8) or_return
				append(&emitter.instructions, x86.inst_r_r(.MOV, x86.R10, source)) or_return
			}
		}
		append(&emitter.instructions, x86.inst_none(.SYSCALL)) or_return
		return nil
	case .Atomic:
		return emit_atomic(emitter, instruction)
	case .Client_Request:
		return emit_client_request(emitter)
	case .Call, .None:
		return lower_instruction(emitter, instruction, block)
	}
	return nil
}

// Valgrind's special instruction sequence: the rotates add up to 128 bits, so RDI is unchanged, and the
// exchange of RBX with itself is the marker Valgrind's translator recognizes. Outside Valgrind it does nothing.
@(private = "file")
emit_client_request :: proc(emitter: ^Emitter) -> Emit_Error {
	for amount in ([?]i8{3, 13, 61, 51}) {
		append(&emitter.instructions, x86.inst_rol_r64_imm8(.RDI, amount)) or_return
	}
	append(&emitter.instructions, x86.inst_xchg_r64_r64(.RBX, .RBX)) or_return
	return nil
}

// Labels number the blocks, then the shared epilogue, then the external symbols, then the instructions.
@(private = "file")
epilogue_label :: proc(function: ^Machine_Function) -> u32 {
	return u32(len(function.blocks))
}

@(private = "file")
external_base :: proc(function: ^Machine_Function) -> int {
	return len(function.blocks) + 1
}

// Every return jumps to the one epilogue, so the callee-saved restores are emitted once per procedure.
@(private = "file")
emit_return_jump :: proc(emitter: ^Emitter) -> Emit_Error {
	label := epilogue_label(emitter.function)
	append(&emitter.branches, Branch{u32(len(emitter.instructions)), label, .JMP}) or_return
	append(&emitter.instructions, x86.inst_rel(.JMP, label, 1)) or_return
	emitter.has_return = true
	return nil
}

// A return that is the last instruction jumps onto the epilogue that directly follows it, so the jump is dropped.
@(private = "file")
drop_final_return_jump :: proc(emitter: ^Emitter) {
	count := len(emitter.branches)
	if count == 0 {
		return
	}
	last := emitter.branches[count - 1]
	if last.block != epilogue_label(emitter.function) || int(last.instruction) != len(emitter.instructions) - 1 {
		return
	}
	pop(&emitter.branches)
	pop(&emitter.instructions)
}

@(private = "file")
location_of :: proc(emitter: ^Emitter, vreg: Vreg) -> (regalloc.Location, Emit_Error) {
	if int(vreg) >= len(emitter.result.location) || emitter.result.location[vreg] == nil {
		return nil, Emit_Failure.Missing_Location
	}
	return emitter.result.location[vreg], nil
}

@(private = "file")
emit_vreg_move :: proc(emitter: ^Emitter, source, destination: Vreg) -> Emit_Error {
	from := location_of(emitter, source) or_return
	to := location_of(emitter, destination) or_return
	return emit_location_move(emitter, emitter.function.vreg_classes[source], from, to)
}

// Emits one copy between the locations of a single register class.
@(private = "file")
emit_location_move :: proc(emitter: ^Emitter, class: Register_Class, from, to: regalloc.Location) -> Emit_Error {
	if from == to {
		return nil
	}
	instructions := &emitter.instructions
	switch from_value in from {
	case regalloc.Register:
		switch to_value in to {
		case regalloc.Register:
			if class == .Int {
				append(instructions, x86.inst_r_r(.MOV, x86.gpr64_from_num(u8(to_value)), x86.gpr64_from_num(u8(from_value)))) or_return
			} else {
				append(instructions, x86.inst_r_r(.MOVAPS, x86.xmm_from_num(u8(to_value)), x86.xmm_from_num(u8(from_value)))) or_return
			}
		case regalloc.Spill_Slot:
			store_spill(emitter, class, u8(from_value), to_value) or_return
		}
	case regalloc.Spill_Slot:
		switch to_value in to {
		case regalloc.Register:
			load_spill(emitter, class, u8(to_value), from_value) or_return
		case regalloc.Spill_Slot:
			number := scratch_registers(class)[1]
			load_spill(emitter, class, number, from_value) or_return
			store_spill(emitter, class, number, to_value) or_return
		}
	}
	return nil
}

@(private = "file")
scratch_registers :: proc(class: Register_Class) -> [2]u8 {
	return INT_SCRATCH_REGISTERS if class == .Int else FLOAT_SCRATCH_REGISTERS
}

@(private = "file")
spill_memory :: proc(emitter: ^Emitter, slot: regalloc.Spill_Slot) -> x86.Memory {
	return x86.mem_base_disp(x86.RBP, spill_offset(emitter.layout, slot))
}

@(private = "file")
load_spill :: proc(emitter: ^Emitter, class: Register_Class, number: u8, slot: regalloc.Spill_Slot) -> runtime.Allocator_Error {
	memory := spill_memory(emitter, slot)
	if class == .Int {
		_, err := append(&emitter.instructions, x86.inst_r_m(.MOV, x86.gpr64_from_num(number), memory, 8))
		return err
	}
	_, err := append(&emitter.instructions, x86.inst_r_m(.MOVUPS, x86.xmm_from_num(number), memory, 16))
	return err
}

@(private = "file")
store_spill :: proc(emitter: ^Emitter, class: Register_Class, number: u8, slot: regalloc.Spill_Slot) -> runtime.Allocator_Error {
	memory := spill_memory(emitter, slot)
	if class == .Int {
		_, err := append(&emitter.instructions, x86.inst_m_r(.MOV, memory, 8, x86.gpr64_from_num(number)))
		return err
	}
	_, err := append(&emitter.instructions, x86.inst_m_r(.MOVUPS, memory, 16, x86.xmm_from_num(number)))
	return err
}

@(private = "file")
take_scratch :: proc(emitter: ^Emitter, class: Register_Class) -> (number: u8, err: Emit_Error) {
	taken := emitter.scratch_taken[class]
	if taken >= 2 {
		return 0, Emit_Failure.Scratch_Exhausted
	}
	emitter.scratch_taken[class] += 1
	return scratch_registers(class)[taken], nil
}

@(private = "file")
release_scratch :: proc(emitter: ^Emitter, class: Register_Class, number: u8) -> Emit_Error {
	taken := emitter.scratch_taken[class]
	if taken == 0 || scratch_registers(class)[taken - 1] != number {
		return Emit_Failure.Bad_Operand
	}
	emitter.scratch_taken[class] -= 1
	return nil
}

@(private = "file")
register_of_width :: proc(class: Register_Class, number: u8, width: u8) -> x86.Register {
	if class == .Float {
		return x86.xmm_from_num(number)
	}
	switch width {
	case 1:
		return x86.gpr8_from_num(number, true)
	case 2:
		return x86.gpr16_from_num(number)
	case 4:
		return x86.gpr32_from_num(number)
	}
	return x86.gpr64_from_num(number)
}

@(private = "file")
Access :: struct {
	reads:  bool,
	writes: bool,
}

// Returns the register holding `vreg` for this instruction: its own, or a scratch register
// that is loaded first when the access reads and stored back afterwards when it writes.
@(private = "file")
vreg_register :: proc(emitter: ^Emitter, vreg: Vreg, access: Access, width: u8) -> (register: x86.Register, err: Emit_Error) {
	class := emitter.function.vreg_classes[vreg]
	location := location_of(emitter, vreg) or_return
	switch value in location {
	case regalloc.Register:
		return register_of_width(class, u8(value), width), nil
	case regalloc.Spill_Slot:
		number := take_scratch(emitter, class) or_return
		if access.reads {
			load_spill(emitter, class, number, value) or_return
		}
		if access.writes {
			emitter.stores[emitter.store_count] = Pending_Store{class, number, value}
			emitter.store_count += 1
		}
		return register_of_width(class, number, width), nil
	}
	return x86.NONE, Emit_Failure.Missing_Location
}

@(private = "file")
external_label :: proc(emitter: ^Emitter, target: Symbol_Target, kind: elf.R_X86_64, addend: i64) -> (label: u32, err: Emit_Error) {
	symbols := emitter.symbols[target.symbol.space]
	if int(target.symbol.index) >= len(symbols) {
		return 0, Emit_Failure.Unknown_Symbol
	}
	append(&emitter.externals, External_Reference{symbols[target.symbol.index], kind, addend}) or_return
	return u32(external_base(emitter.function) + len(emitter.externals) - 1), nil
}

@(private = "file")
lower_memory :: proc(emitter: ^Emitter, reference: Memory_Ref) -> (memory: x86.Memory, err: Emit_Error) {
	displacement := i64(reference.displacement)
	base := x86.NONE
	base_vreg: Vreg
	base_is_vreg := false
	switch value in reference.base {
	case Vreg:
		base_vreg, base_is_vreg = value, true
	case Frame_Object:
		base = x86.RBP
		switch value.kind {
		case .Slot:
			if int(value.index) >= len(emitter.layout.slot_offsets) {
				return {}, Emit_Failure.Bad_Operand
			}
			displacement += i64(emitter.layout.slot_offsets[value.index])
		case .Spill:
			displacement += i64(spill_offset(emitter.layout, regalloc.Spill_Slot(value.index)))
		case .Incoming:
			displacement += 16 + i64(value.index)
		case .Outgoing:
			base = x86.RSP
			displacement += i64(value.index)
		}
	case Symbol_Target:
		if reference.has_index || reference.segment_fs {
			return {}, Emit_Failure.Bad_Operand
		}
		label := external_label(emitter, value, .R_X86_64_PC32, value.addend + displacement - 4) or_return
		return x86.mem_rip_label(label), nil
	}
	index := x86.NONE
	if reference.has_index {
		if base_is_vreg {
			index_vreg := reference.index
			base_location := location_of(emitter, base_vreg) or_return
			index_location := location_of(emitter, index_vreg) or_return
			_, base_is_spilled := base_location.(regalloc.Spill_Slot)
			_, index_is_spilled := index_location.(regalloc.Spill_Slot)
			if base_is_spilled && index_is_spilled {
				if displacement != i64(i32(displacement)) { return {}, Emit_Failure.Bad_Operand }
				if emitter.function.vreg_classes[base_vreg] != .Int || emitter.function.vreg_classes[index_vreg] != .Int {
					return {}, Emit_Failure.Bad_Operand
				}
				base = vreg_register(emitter, base_vreg, {reads = true}, 8) or_return
				index = vreg_register(emitter, index_vreg, {reads = true}, 8) or_return
				scale := max(reference.scale, 1)
				if scale != 1 && scale != 2 && scale != 4 && scale != 8 { return {}, Emit_Failure.Bad_Operand }
				address := x86.mem_make(base, index, scale, i32(displacement), x86.NONE)
				append(&emitter.instructions, x86.inst_r_m(.LEA, base, address, 8)) or_return
				release_scratch(emitter, .Int, scratch_registers(.Int)[1]) or_return
				return x86.mem_make(base, x86.NONE, 1, 0, x86.NONE), nil
			}
		}
		if base_is_vreg {
			base = vreg_register(emitter, base_vreg, {reads = true}, 8) or_return
		}
		index = vreg_register(emitter, reference.index, {reads = true}, 8) or_return
	} else if base_is_vreg {
		base = vreg_register(emitter, base_vreg, {reads = true}, 8) or_return
	}
	if displacement != i64(i32(displacement)) {
		return {}, Emit_Failure.Bad_Operand
	}
	return x86.mem_make(base, index, max(reference.scale, 1), i32(displacement), x86.FS if reference.segment_fs else x86.NONE), nil
}

@(private = "file")
operand_width :: proc(instruction: Machine_Instruction, index: int) -> u8 {
	#partial switch instruction.mnemonic {
	case .MOVZX, .MOVSX:
		return 4 if index == 0 else instruction.width
	case .MOVSXD:
		return 8 if index == 0 else 4
	case .SHL, .SHR, .SAR:
		return 1 if index == 2 else instruction.width
	case .CALL:
		return 8
	}
	return instruction.width
}

@(private = "file")
lower_instruction :: proc(emitter: ^Emitter, instruction: Machine_Instruction, block: u32) -> Emit_Error {
	emitter.scratch_taken = {}
	emitter.store_count = 0
	info: Op_Info
	if instruction.pseudo == .None {
		known: bool
		info, known = instruction_info(instruction)
		if !known {
			return Emit_Failure.Bad_Operand
		}
	}
	explicit := instruction.operands[:instruction.explicit_count]
	if len(explicit) == 1 && (info.branch || info.terminator) {
		if target, is_block := explicit[0].(Block_Ref); is_block {
			if instruction.mnemonic == .JMP {
				if u32(target) == block + 1 || fall_through_by_inverting(emitter, block, u32(target)) {
					return nil
				}
			}
			append(&emitter.branches, Branch{u32(len(emitter.instructions)), u32(target), instruction.mnemonic}) or_return
			append(&emitter.instructions, x86.inst_rel(instruction.mnemonic, u32(target), 1)) or_return
			return nil
		}
	}

	destination_is_vreg := false
	if len(explicit) > 0 {
		_, destination_is_vreg = explicit[0].(Vreg)
	}
	reuses := destination_is_vreg && reuses_first_input(instruction, info)
	lowered: x86.Instruction
	lowered.mnemonic = instruction.mnemonic
	if instruction.rep {
		lowered.flags.rep = .REP
	}
	output_index := 0
	for operand, index in explicit {
		if reuses && index == 1 { continue }
		if memory, is_memory := operand.(Memory_Ref); is_memory {
			slot := &lowered.ops[output_index]
			slot^ = x86.op_mem(lower_memory(emitter, memory) or_return, operand_width(instruction, index))
			if memory.segment_fs { lowered.flags.segment = FS_SEGMENT_INDEX }
		}
		output_index += 1
	}
	for operand, index in explicit {
		if reuses && index == 1 {
			continue
		}
		access: Access
		switch {
		case instruction.pseudo == .Call:
			access = {
				reads = true,
			}
		case reuses && index == 0:
			access = {true, true}
		case index < len(info.access):
			access = {info.access[index] == .Use, info.access[index] == .Def}
		}
		width := operand_width(instruction, index)
		slot := &lowered.ops[lowered.operand_count]
		switch value in operand {
		case Vreg:
			slot^ = x86.op_reg(vreg_register(emitter, value, access, width) or_return)
		case Fixed_Vreg:
			class := emitter.function.vreg_classes[value.vreg]
			slot^ = x86.op_reg(register_of_width(class, u8(value.register), width))
		case Physical_Register:
			slot^ = x86.op_reg(register_of_width(.Int, u8(value), width))
		case Immediate:
			slot^ = x86.op_imm(i64(value), 8 if instruction.mnemonic == .MOVABS else min(width, 4))
		case Memory_Ref:
			lowered.operand_count += 1
			continue
		case Symbol_Target:
			label := external_label(emitter, value, .R_X86_64_PLT32, value.addend - 4) or_return
			slot^ = x86.op_label(label, 4)
		case Thread_Pointer_Offset:
			label := external_label(emitter, Symbol_Target{symbol = value.symbol}, .R_X86_64_TPOFF64, 0) or_return
			slot^ = x86.op_imm_label(label)
		case Block_Ref:
			return Emit_Failure.Bad_Operand
		}
		lowered.operand_count += 1
	}
	if len(explicit) == 3 && (instruction.mnemonic == .SHL || instruction.mnemonic == .SHR || instruction.mnemonic == .SAR) {
		if _, is_immediate := explicit[2].(Immediate); is_immediate {
			lowered.enc_hint = shift_immediate_hint(instruction.mnemonic, instruction.width)
		}
	}
	append(&emitter.instructions, lowered) or_return
	for store in emitter.stores[:emitter.store_count] {
		store_spill(emitter, store.class, store.number, store.slot) or_return
	}
	return nil
}

// When the conditional branch just emitted jumps to the next block, the unconditional jump that
// follows it is replaced by the inverted branch to `target`, which then falls through.
@(private = "file")
fall_through_by_inverting :: proc(emitter: ^Emitter, block: u32, target: u32) -> bool {
	if len(emitter.branches) == 0 {
		return false
	}
	branch := &emitter.branches[len(emitter.branches) - 1]
	inverse, invertible := inverted_condition(branch.mnemonic)
	if !invertible ||
	   branch.block != block + 1 ||
	   int(branch.instruction) != len(emitter.instructions) - 1 ||
	   int(branch.instruction) < int(emitter.block_first[block]) {
		return false
	}
	branch.mnemonic = inverse
	branch.block = target
	emitter.instructions[branch.instruction] = x86.inst_rel(inverse, target, 1)
	return true
}

@(private = "file")
inverted_condition :: proc(mnemonic: x86.Mnemonic) -> (inverse: x86.Mnemonic, ok: bool) {
	#partial switch mnemonic {
	case .JE:
		return .JNE, true
	case .JNE:
		return .JE, true
	case .JL:
		return .JGE, true
	case .JGE:
		return .JL, true
	case .JLE:
		return .JG, true
	case .JG:
		return .JLE, true
	case .JB:
		return .JAE, true
	case .JAE:
		return .JB, true
	case .JBE:
		return .JA, true
	case .JA:
		return .JBE, true
	case .JP:
		return .JNP, true
	case .JNP:
		return .JP, true
	}
	return mnemonic, false
}

// The encoder's form-match cache keys an immediate by value class, and -128..127 is one class, but only
// the D0/D1 shift-by-one forms match exactly 1. The builders pin the imm8 form (C0/C1 /n ib) instead;
// SAL, ROL, ROR, RCL and RCR would need the same hint if they were ever emitted with an immediate.
@(private = "file")
shift_immediate_hint :: proc(mnemonic: x86.Mnemonic, width: u8) -> u16 {
	#partial switch mnemonic {
	case .SHL:
		switch width {
		case 1:
			return x86.inst_shl_r8_imm8(.AL, 0).enc_hint
		case 2:
			return x86.inst_shl_r16_imm8(.AX, 0).enc_hint
		case 4:
			return x86.inst_shl_r32_imm8(.EAX, 0).enc_hint
		}
		return x86.inst_shl_r64_imm8(.RAX, 0).enc_hint
	case .SHR:
		switch width {
		case 1:
			return x86.inst_shr_r8_imm8(.AL, 0).enc_hint
		case 2:
			return x86.inst_shr_r16_imm8(.AX, 0).enc_hint
		case 4:
			return x86.inst_shr_r32_imm8(.EAX, 0).enc_hint
		}
		return x86.inst_shr_r64_imm8(.RAX, 0).enc_hint
	case .SAR:
		switch width {
		case 1:
			return x86.inst_sar_r8_imm8(.AL, 0).enc_hint
		case 2:
			return x86.inst_sar_r16_imm8(.AX, 0).enc_hint
		case 4:
			return x86.inst_sar_r32_imm8(.EAX, 0).enc_hint
		}
		return x86.inst_sar_r64_imm8(.RAX, 0).enc_hint
	}
	return 0
}

@(private = "file")
emit_atomic :: proc(emitter: ^Emitter, instruction: Machine_Instruction) -> Emit_Error {
	emitter.scratch_taken = {}
	emitter.store_count = 0
	address, address_ok := instruction.operands[0].(Memory_Ref)
	accumulator, accumulator_ok := instruction.operands[1].(Fixed_Vreg)
	if !address_ok || !accumulator_ok { return Emit_Failure.Bad_Operand }
	memory := lower_memory(emitter, address) or_return
	width := instruction.width
	register := register_of_width(.Int, u8(accumulator.register), width)
	mnemonic := instruction.mnemonic
	if mnemonic == .XADD || mnemonic == .XCHG {
		atomic := x86.inst_m_r(mnemonic, memory, width, register)
		atomic.flags.lock = mnemonic == .XADD
		if address.segment_fs { atomic.flags.segment = FS_SEGMENT_INDEX }
		append(&emitter.instructions, atomic) or_return
		return nil
	}
	operand: x86.Register
	if mnemonic == .CMPXCHG {
		value, value_ok := instruction.operands[2].(Vreg)
		if !value_ok { return Emit_Failure.Bad_Operand }
		operand = vreg_register(emitter, value, {reads = true}, width) or_return
	} else {
		value, value_ok := instruction.operands[2].(Fixed_Vreg)
		if !value_ok || value.register != gpr(.RCX) { return Emit_Failure.Bad_Operand }
		operand = register_of_width(.Int, u8(value.register), width)
	}
	replacement := operand
	loop_start: u32
	if mnemonic != .CMPXCHG {
		temporary, temporary_ok := instruction.operands[3].(Fixed_Vreg)
		if !temporary_ok { return Emit_Failure.Bad_Operand }
		replacement = register_of_width(.Int, u8(temporary.register), width)
		load := x86.inst_r_m(.MOVZX if width < 4 else .MOV, register_of_width(.Int, u8(accumulator.register), max(4, width)), memory, width)
		if address.segment_fs { load.flags.segment = FS_SEGMENT_INDEX }
		append(&emitter.instructions, load) or_return
		loop_start = u32(len(emitter.instructions))
		append(&emitter.instructions, x86.inst_r_r(.MOV, replacement, register)) or_return
		append(&emitter.instructions, x86.inst_r_r(.AND if mnemonic == .NOT else mnemonic, replacement, operand)) or_return
		if mnemonic == .NOT { append(&emitter.instructions, x86.inst_r(.NOT, replacement)) or_return }
	}
	atomic := x86.inst_m_r(.CMPXCHG, memory, width, replacement)
	atomic.flags.lock = true
	if address.segment_fs { atomic.flags.segment = FS_SEGMENT_INDEX }
	append(&emitter.instructions, atomic) or_return
	if mnemonic != .CMPXCHG {
		append(&emitter.local_branches, Branch{u32(len(emitter.instructions)), loop_start, .JNE}) or_return
		append(&emitter.instructions, x86.inst_rel(.JNE, 0, 1)) or_return
	}
	return nil
}

package amd64

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import x86 "core:rexcode/isa/x86"
import "oc:elf"
import "oc:ir"
import "oc:link"
import "oc:regalloc"

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
	function:      ^Machine_Function,
	result:        ^regalloc.Result,
	layout:        Frame_Layout,
	symbols:       Symbol_Indices,
	instructions:  [dynamic]x86.Instruction,
	block_first:   []u32,
	externals:     [dynamic]External_Reference,
	branches:      [dynamic]Branch,
	scratch_taken: [Register_Class]int,
	stores:        [4]Pending_Store,
	store_count:   int,
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
	scratch: virtual.Arena
	virtual.arena_init_growing(&scratch) or_return
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)

	emitter := Emitter {
		function = function,
		result   = result,
		symbols  = symbols,
	}
	emitter.layout = frame_layout(function, result, context.allocator) or_return
	emitter.block_first = make([]u32, len(function.blocks)) or_return
	emit_prologue(&emitter.instructions, emitter.layout) or_return

	move_cursor := 0
	for block, block_index in function.blocks {
		emitter.block_first[block_index] = u32(len(emitter.instructions))
		for instruction, instruction_index in block.instructions {
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

	code, unresolved := relax_and_encode(&emitter) or_return
	bytes := make([]byte, len(code), allocator) or_return
	copy(bytes, code)
	relocations, alloc_err := make([]link.Relocation, len(unresolved), allocator)
	if alloc_err != nil {
		delete(bytes, allocator)
		return {}, alloc_err
	}
	for relocation, index in unresolved {
		external := emitter.externals[int(relocation.label_id) - len(function.blocks)]
		relocations[index] = link.Relocation {
			offset = relocation.offset,
			symbol = external.symbol,
			kind   = external.kind,
			addend = external.addend,
		}
	}
	return link.Atom{section = .Text, align = 16, bytes = bytes, size = u64(len(bytes)), relocs = relocations}, nil
}

atom_destroy :: proc(atom: ^link.Atom, allocator: mem.Allocator) {
	delete(atom.bytes, allocator)
	delete(atom.relocs, allocator)
	atom^ = {}
}

@(private = "file")
relax_and_encode :: proc(emitter: ^Emitter) -> (code: []byte, unresolved: []x86.Relocation, err: Emit_Error) {
	block_count := len(emitter.function.blocks)
	instruction_count := len(emitter.instructions)
	instruction_label_base := block_count + len(emitter.externals)
	label_defs := make([]x86.Label_Definition, instruction_label_base + instruction_count) or_return
	buffer := make([]byte, (instruction_count + 1) * x86.MAX_INST_SIZE) or_return
	relocations := make([dynamic]x86.Relocation) or_return
	errors := make([dynamic]x86.Error) or_return

	fill_labels :: proc(emitter: ^Emitter, label_defs: []x86.Label_Definition, instruction_label_base: int) {
		for first, block_index in emitter.block_first {
			label_defs[block_index] = x86.Label_Definition(first)
		}
		for index in len(emitter.block_first) ..< instruction_label_base {
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
	return buffer[:byte_count], relocations[:], nil
}

@(private = "file")
emit_instruction_body :: proc(emitter: ^Emitter, instruction: Machine_Instruction, block: u32) -> Emit_Error {
	switch instruction.pseudo {
	case .Entry:
		return nil
	case .Return:
		return emit_epilogue(&emitter.instructions, emitter.layout)
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
	case .Call, .None:
		return lower_instruction(emitter, instruction, block)
	}
	return nil
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
	if from == to {
		return nil
	}
	class := emitter.function.vreg_classes[source]
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
	return u32(len(emitter.function.blocks) + len(emitter.externals) - 1), nil
}

@(private = "file")
lower_memory :: proc(emitter: ^Emitter, reference: Memory_Ref) -> (memory: x86.Memory, err: Emit_Error) {
	displacement := i64(reference.displacement)
	base := x86.NONE
	switch value in reference.base {
	case Vreg:
		base = vreg_register(emitter, value, {reads = true}, 8) or_return
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
		index = vreg_register(emitter, reference.index, {reads = true}, 8) or_return
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
		info, known = op_info(instruction.mnemonic)
		if !known {
			return Emit_Failure.Bad_Operand
		}
	}
	explicit := instruction.operands[:instruction.explicit_count]
	if len(explicit) == 1 && (info.branch || info.terminator) {
		if target, is_block := explicit[0].(Block_Ref); is_block {
			if instruction.mnemonic == .JMP && u32(target) == block + 1 {
				return nil
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
			slot^ = x86.op_mem(lower_memory(emitter, value) or_return, width)
		case Symbol_Target:
			label := external_label(emitter, value, .R_X86_64_PLT32, value.addend - 4) or_return
			slot^ = x86.op_label(label, 4)
		case Block_Ref:
			return Emit_Failure.Bad_Operand
		}
		lowered.operand_count += 1
	}
	append(&emitter.instructions, lowered) or_return
	for store in emitter.stores[:emitter.store_count] {
		store_spill(emitter, store.class, store.number, store.slot) or_return
	}
	return nil
}

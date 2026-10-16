package amd64

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import x86 "core:rexcode/isa/x86"
import "core:strings"
import "oc:ir"
import "oc:regalloc"

Vreg :: regalloc.Vreg
Register_Class :: regalloc.Register_Class

// Gpr values are the hardware register numbers, which are also the
// `regalloc.Register` numbers of the `Int` bank; `Float` registers are `xmm` numbers.
Gpr :: enum u8 {
	RAX,
	RCX,
	RDX,
	RBX,
	RSP,
	RBP,
	RSI,
	RDI,
	R8,
	R9,
	R10,
	R11,
	R12,
	R13,
	R14,
	R15,
}

// Scratch registers belong to `emit` (spill reloads, memory-to-memory moves, syscall
// argument 4) and are never allocated: they are missing from the allocatable sets.
INT_ALLOCATABLE :: regalloc.Register_Set {
	int(Gpr.RAX),
	int(Gpr.RCX),
	int(Gpr.RDX),
	int(Gpr.RBX),
	int(Gpr.RSI),
	int(Gpr.RDI),
	int(Gpr.R8),
	int(Gpr.R9),
	int(Gpr.R12),
	int(Gpr.R13),
	int(Gpr.R14),
	int(Gpr.R15),
}
INT_CALLEE_SAVED :: regalloc.Register_Set{int(Gpr.RBX), int(Gpr.R12), int(Gpr.R13), int(Gpr.R14), int(Gpr.R15)}
INT_SCRATCH :: regalloc.Register_Set{int(Gpr.R10), int(Gpr.R11)}
FLOAT_ALLOCATABLE :: regalloc.Register_Set{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13}
FLOAT_SCRATCH :: regalloc.Register_Set{14, 15}

CALL_CLOBBERS :: [Register_Class]regalloc.Register_Set {
	.Int   = {int(Gpr.RAX), int(Gpr.RCX), int(Gpr.RDX), int(Gpr.RSI), int(Gpr.RDI), int(Gpr.R8), int(Gpr.R9)},
	.Float = FLOAT_ALLOCATABLE,
}

allocatable_registers :: proc(class: Register_Class) -> regalloc.Register_Set {
	return INT_ALLOCATABLE if class == .Int else FLOAT_ALLOCATABLE
}

// Fixed_Vreg pins a virtual register to one machine register at one instruction.
Fixed_Vreg :: struct {
	vreg:     Vreg,
	register: regalloc.Register,
	role:     regalloc.Operand_Role,
}

Immediate :: distinct i64

Block_Ref :: distinct u32

Symbol_Target :: struct {
	symbol: ir.Symbol_Ref,
	addend: i64,
}

// Frame_Object names frame memory the frame layout places later. `index` is the byte
// offset in the stack-argument area for `Incoming` and `Outgoing`, and the object id
// for `Slot` and `Spill`.
Frame_Object_Kind :: enum u8 {
	Slot,
	Spill,
	Incoming,
	Outgoing,
}

Frame_Object :: struct {
	kind:  Frame_Object_Kind,
	index: u32,
}

Memory_Base :: union {
	Vreg,
	Frame_Object,
	Symbol_Target,
}

Memory_Ref :: struct {
	base:         Memory_Base,
	index:        Vreg,
	has_index:    bool,
	scale:        u8,
	displacement: i32,
	segment_fs:   bool,
}

Machine_Operand :: union {
	Vreg,
	Fixed_Vreg,
	Immediate,
	Memory_Ref,
	Block_Ref,
	Symbol_Target,
}

// Pseudo instructions expand in `emit`. `Entry` defines the register parameters,
// `Call` and `Return` carry the argument and result registers as fixed operands,
// `Copy` is a register-to-register move within one class.
Pseudo :: enum u8 {
	None,
	Entry,
	Call,
	Return,
	Copy,
}

// operands[:explicit_count] go to the encoder; the rest only constrain the allocator.
Machine_Instruction :: struct {
	mnemonic:       x86.Mnemonic,
	pseudo:         Pseudo,
	width:          u8,
	explicit_count: u8,
	rep:            bool,
	operands:       []Machine_Operand,
	clobbers:       [Register_Class]regalloc.Register_Set,
}

Machine_Block :: struct {
	instructions: [dynamic]Machine_Instruction,
	successors:   [dynamic]u32,
	depth:        u8,
	cold:         bool,
}

Frame_Slot :: struct {
	size:  u32,
	align: u32,
}

// A Machine_Function owns everything it references in its arena, so it must not be
// moved after `machine_function_init`.
Machine_Function :: struct {
	name:           string,
	blocks:         [dynamic]Machine_Block,
	vreg_classes:   [dynamic]Register_Class,
	frame_slots:    [dynamic]Frame_Slot,
	outgoing_bytes: u32,
	arena:          virtual.Arena,
}

machine_function_init :: proc(function: ^Machine_Function, name: string) -> (err: runtime.Allocator_Error) {
	function^ = {}
	virtual.arena_init_growing(&function.arena) or_return
	defer if err != nil {
		virtual.arena_destroy(&function.arena)
	}
	allocator := virtual.arena_allocator(&function.arena)
	function.name = strings.clone(name, allocator) or_return
	function.blocks = make([dynamic]Machine_Block, allocator) or_return
	function.vreg_classes = make([dynamic]Register_Class, allocator) or_return
	function.frame_slots = make([dynamic]Frame_Slot, allocator) or_return
	return nil
}

machine_function_destroy :: proc(function: ^Machine_Function) {
	virtual.arena_destroy(&function.arena)
	function^ = {}
}

new_vreg :: proc(function: ^Machine_Function, class: Register_Class) -> (Vreg, runtime.Allocator_Error) {
	vreg := Vreg(len(function.vreg_classes))
	_, err := append(&function.vreg_classes, class)
	return vreg, err
}

// Adds a `Frame_Object{.Slot, index}` object; `align` is at most 16.
add_frame_slot :: proc(function: ^Machine_Function, size, align: u32) -> (index: u32, err: runtime.Allocator_Error) {
	index = u32(len(function.frame_slots))
	_, err = append(&function.frame_slots, Frame_Slot{size, align})
	return index, err
}

add_block :: proc(function: ^Machine_Function) -> (index: u32, err: runtime.Allocator_Error) {
	allocator := virtual.arena_allocator(&function.arena)
	block := Machine_Block {
		instructions = make([dynamic]Machine_Instruction, allocator) or_return,
		successors   = make([dynamic]u32, allocator) or_return,
	}
	index = u32(len(function.blocks))
	append(&function.blocks, block) or_return
	return index, nil
}

// Appends `instruction` to `block`; its operand slice is copied into the function's arena.
emit_instruction :: proc(function: ^Machine_Function, block: u32, instruction: Machine_Instruction) -> runtime.Allocator_Error {
	allocator := virtual.arena_allocator(&function.arena)
	stored := instruction
	stored.operands = make([]Machine_Operand, len(instruction.operands), allocator) or_return
	copy(stored.operands, instruction.operands)
	_, err := append(&function.blocks[block].instructions, stored)
	return err
}

// Appends an ordinary instruction whose operands all go to the encoder.
emit :: proc(function: ^Machine_Function, block: u32, mnemonic: x86.Mnemonic, width: u8, operands: ..Machine_Operand) -> runtime.Allocator_Error {
	return emit_instruction(function, block, Machine_Instruction{mnemonic = mnemonic, width = width, explicit_count = u8(len(operands)), operands = operands})
}

emit_pseudo :: proc(function: ^Machine_Function, block: u32, pseudo: Pseudo, operands: ..Machine_Operand) -> runtime.Allocator_Error {
	return emit_instruction(function, block, Machine_Instruction{pseudo = pseudo, operands = operands})
}

fixed :: proc(vreg: Vreg, register: regalloc.Register, role: regalloc.Operand_Role) -> Fixed_Vreg {
	return Fixed_Vreg{vreg, register, role}
}

gpr :: proc(register: Gpr) -> regalloc.Register {
	return regalloc.Register(register)
}

print_function :: proc(function: ^Machine_Function, builder: ^strings.Builder) {
	fmt.sbprintfln(builder, "machine %s outgoing=%d", function.name, function.outgoing_bytes)
	for block, block_index in function.blocks {
		fmt.sbprintf(builder, "b%d:", block_index)
		if block.cold {
			strings.write_string(builder, " cold")
		}
		strings.write_string(builder, "\n")
		for instruction in block.instructions {
			strings.write_string(builder, "  ")
			if instruction.pseudo != .None {
				fmt.sbprintf(builder, "%v", instruction.pseudo)
			} else {
				fmt.sbprintf(builder, "%v", instruction.mnemonic)
				if instruction.width != 0 {
					fmt.sbprintf(builder, ".%d", instruction.width)
				}
			}
			for operand, operand_index in instruction.operands {
				strings.write_string(builder, ", " if operand_index > 0 else " ")
				print_operand(builder, operand)
			}
			strings.write_string(builder, "\n")
		}
	}
}

@(private = "file")
print_operand :: proc(builder: ^strings.Builder, operand: Machine_Operand) {
	switch value in operand {
	case Vreg:
		fmt.sbprintf(builder, "v%d", u32(value))
	case Fixed_Vreg:
		fmt.sbprintf(builder, "v%d@%d", u32(value.vreg), value.register)
	case Immediate:
		fmt.sbprintf(builder, "#%d", i64(value))
	case Block_Ref:
		fmt.sbprintf(builder, "b%d", u32(value))
	case Symbol_Target:
		fmt.sbprintf(builder, "sym%d.%d%+d", u8(value.symbol.space), value.symbol.index, value.addend)
	case Memory_Ref:
		strings.write_string(builder, "[fs:" if value.segment_fs else "[")
		switch base in value.base {
		case Vreg:
			fmt.sbprintf(builder, "v%d", u32(base))
		case Frame_Object:
			fmt.sbprintf(builder, "%v%d", base.kind, base.index)
		case Symbol_Target:
			fmt.sbprintf(builder, "rip+sym%d.%d%+d", u8(base.symbol.space), base.symbol.index, base.addend)
		}
		if value.has_index {
			fmt.sbprintf(builder, "+v%d*%d", u32(value.index), value.scale)
		}
		if value.displacement != 0 {
			fmt.sbprintf(builder, "%+d", value.displacement)
		}
		strings.write_string(builder, "]")
	case:
		strings.write_string(builder, "_")
	}
}

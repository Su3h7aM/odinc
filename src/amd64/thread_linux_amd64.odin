package amd64

import "base:runtime"
import x86 "core:rexcode/isa/x86"
import "oc:link"

// Hand-encoded Linux x86-64 thread primitives. These are faithful translations
// of the fork's `core/sys/linux/clone_amd64.asm` (`_odin_linux_clone`) and
// `base/runtime/tls_linux_no_crt_amd64.asm` (`_odin_linux_tls_layout`): the
// same instructions in the same order, verified against the decoded bytes.
// Both bodies are position-independent and reference no outside symbol, so
// their atoms carry no relocations. There is no assembler toolchain; the
// encoder is the same `core:rexcode/isa/x86` the `amd64` package already uses.

// Forward jump targets are slots in a heap table: reserve a slot, emit jumps
// at it, bind the instruction index, then patch every jump. Rel32 needs no
// relaxation, so one encode pass suffices.
@(private)
Pending_Branch :: struct {
	instruction: int,
	mnemonic:    x86.Mnemonic,
	target:      int,
}

@(private)
reserve_branch :: proc(targets: ^[dynamic]int) -> (slot: int, err: runtime.Allocator_Error) {
	slot = len(targets)
	append(targets, -1) or_return
	return slot, nil
}

@(private)
emit_branch :: proc(
	instructions: ^[dynamic]x86.Instruction,
	branches: ^[dynamic]Pending_Branch,
	mnemonic: x86.Mnemonic,
	slot: int,
) -> runtime.Allocator_Error {
	append(branches, Pending_Branch{len(instructions), mnemonic, slot}) or_return
	append(instructions, x86.inst_rel(mnemonic, 0, 4)) or_return
	return nil
}

@(private)
bind_branch :: proc(targets: ^[dynamic]int, slot: int, instructions: []x86.Instruction) {
	targets[slot] = len(instructions)
}

@(private)
resolve_branches :: proc(instructions: []x86.Instruction, branches: []Pending_Branch, targets: []int, local_base: u32) -> bool {
	for branch in branches {
		if branch.target < 0 || branch.target >= len(targets) { return false }
		index := targets[branch.target]
		if index < 0 { return false }
		instructions[branch.instruction] = x86.inst_rel(branch.mnemonic, local_base + u32(index), 4)
	}
	return true
}

// Encodes branch-carrying instructions with no external references as one text
// atom. Resolution patches the local jumps in place; any relocation left over
// names an undefined label, which is a bug.
@(private)
encode_branch_atom :: proc(
	instructions: []x86.Instruction,
	branches: []Pending_Branch,
	targets: []int,
	allocator: runtime.Allocator,
) -> (
	atom: link.Atom,
	err: Emit_Error,
) {
	if !resolve_branches(instructions, branches, targets, 0) {
		return {}, Emit_Error(Emit_Failure.Encoding_Failed)
	}
	definitions := make([]x86.Label_Definition, len(instructions), allocator) or_return
	defer delete(definitions, allocator)
	for index in 0 ..< len(instructions) {
		definitions[index] = x86.Label_Definition(u32(index))
	}
	buffer := make([]byte, len(instructions) * x86.MAX_INST_SIZE, allocator) or_return
	defer delete(buffer, allocator)
	relocations := make([dynamic]x86.Relocation, allocator) or_return
	defer delete(relocations)
	encode_errors := make([dynamic]x86.Error, allocator) or_return
	defer delete(encode_errors)
	byte_count, ok := x86.encode(instructions, definitions, buffer, &relocations, &encode_errors, resolve = true)
	if !ok || len(encode_errors) != 0 || len(relocations) != 0 {
		return {}, Emit_Error(Emit_Failure.Encoding_Failed)
	}
	bytes := make([]byte, int(byte_count), allocator) or_return
	defer if atom.bytes == nil { delete(bytes, allocator) }
	copy(bytes, buffer[:byte_count])
	atom = link.Atom {
		section = .Text,
		align   = 16,
		bytes   = bytes,
		size    = u64(len(bytes)),
	}
	return atom, nil
}

// Emits `_odin_linux_rt_sigreturn`: the signal restorer of core/sys/linux/sigreturn_amd64.asm. Runs with the signal
// frame at the top of the stack, so it touches nothing but rax before the syscall (15, rt_sigreturn).
emit_linux_rt_sigreturn :: proc(allocator: runtime.Allocator) -> (atom: link.Atom, err: Emit_Error) {
	instructions := make([dynamic]x86.Instruction, 0, 3, allocator) or_return
	defer delete(instructions)
	append(&instructions, x86.inst_mov_r32_imm32(.EAX, 15)) or_return
	append(&instructions, x86.inst_syscall_none()) or_return
	append(&instructions, x86.inst_ud2_none()) or_return
	return encode_branch_atom(instructions[:], nil, nil, allocator)
}

// Emits `_odin_linux_clone`: create a child running fn(arg) on the supplied
// stack. The child cannot use the parent's return frame, so the raw clone
// syscall (56) runs with the callback and argument pushed on the child stack;
// the child pops them, calls fn, and exits (60), never exit_group. Follows
// the clone(2) callback interface, not the raw syscall's argument order:
// flags in rdi, parent_tid in rdx, child_tid in r10, tls in r8.
emit_linux_clone :: proc(allocator: runtime.Allocator) -> (atom: link.Atom, err: Emit_Error) {
	instructions := make([dynamic]x86.Instruction, 0, 24, allocator) or_return
	defer delete(instructions)
	branches := make([dynamic]Pending_Branch, 0, 2, allocator) or_return
	defer delete(branches)
	targets := make([dynamic]int, 0, 2, allocator) or_return
	defer delete(targets)
	child := reserve_branch(&targets) or_return

	append(&instructions, x86.inst_and_r64_imm32(.RSI, -16)) or_return
	append(&instructions, x86.inst_sub_r64_imm32(.RSI, 16)) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_base_only(x86.RSI)), .RDI)) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_base_disp(x86.RSI, 8)), .RCX)) or_return
	append(&instructions, x86.inst_mov_r64_r64(.RDI, .RDX)) or_return
	append(&instructions, x86.inst_mov_r64_r64(.RDX, .R8)) or_return
	append(&instructions, x86.inst_mov_r64_m64(.R10, x86.mem64(x86.mem_base_disp(x86.RSP, 8)))) or_return
	append(&instructions, x86.inst_mov_r64_r64(.R8, .R9)) or_return
	append(&instructions, x86.inst_mov_r32_imm32(.EAX, 56)) or_return
	append(&instructions, x86.inst_syscall_none()) or_return
	append(&instructions, x86.inst_test_r64_r64(.RAX, .RAX)) or_return
	emit_branch(&instructions, &branches, .JZ, child) or_return
	append(&instructions, x86.inst_ret_none()) or_return
	bind_branch(&targets, child, instructions[:])
	append(&instructions, x86.inst_xor_r32_r32(.EBP, .EBP)) or_return
	append(&instructions, x86.inst_pop_r64(.RAX)) or_return
	append(&instructions, x86.inst_pop_r64(.RDI)) or_return
	append(&instructions, x86.inst_call_r64(.RAX)) or_return
	append(&instructions, x86.inst_mov_r32_r32(.EDI, .EAX)) or_return
	append(&instructions, x86.inst_mov_r32_imm32(.EAX, 60)) or_return
	append(&instructions, x86.inst_syscall_none()) or_return
	append(&instructions, x86.inst_ud2_none()) or_return
	return encode_branch_atom(instructions[:], branches[:], targets[:], allocator)
}

// Emits `_odin_linux_tls_layout`: read one PT_TLS program header into the six
// words at out (size, alignment, TP bias, signed block offset, image, filesz).
// A null header yields the startup TCB layout. False means an invalid header.
emit_linux_tls_layout :: proc(allocator: runtime.Allocator) -> (atom: link.Atom, err: Emit_Error) {
	instructions := make([dynamic]x86.Instruction, 0, 56, allocator) or_return
	defer delete(instructions)
	branches := make([dynamic]Pending_Branch, 0, 12, allocator) or_return
	defer delete(branches)
	targets := make([dynamic]int, 0, 6, allocator) or_return
	defer delete(targets)
	empty := reserve_branch(&targets) or_return
	fail := reserve_branch(&targets) or_return
	alignment := reserve_branch(&targets) or_return
	sized := reserve_branch(&targets) or_return

	append(&instructions, x86.inst_test_r64_r64(.RDI, .RDI)) or_return
	emit_branch(&instructions, &branches, .JZ, empty) or_return
	append(&instructions, x86.inst_mov_r64_m64(.R8, x86.mem64(x86.mem_base_disp(x86.RDI, 40)))) or_return
	append(&instructions, x86.inst_mov_r64_m64(.R9, x86.mem64(x86.mem_base_disp(x86.RDI, 32)))) or_return
	append(&instructions, x86.inst_cmp_r64_r64(.R9, .R8)) or_return
	emit_branch(&instructions, &branches, .JA, fail) or_return
	append(&instructions, x86.inst_mov_r64_m64(.R10, x86.mem64(x86.mem_base_disp(x86.RDI, 16)))) or_return
	append(&instructions, x86.inst_mov_r64_r64(.RAX, .R10)) or_return
	append(&instructions, x86.inst_add_r64_r64(.RAX, .R9)) or_return
	emit_branch(&instructions, &branches, .JC, fail) or_return
	append(&instructions, x86.inst_mov_r64_m64(.RCX, x86.mem64(x86.mem_base_disp(x86.RDI, 48)))) or_return
	append(&instructions, x86.inst_test_r64_r64(.RCX, .RCX)) or_return
	emit_branch(&instructions, &branches, .JNZ, alignment) or_return
	append(&instructions, x86.inst_mov_r32_imm32(.ECX, 1)) or_return
	bind_branch(&targets, alignment, instructions[:])
	append(&instructions, x86.inst_lea_r64_m(.RDX, x86.mem_base_disp(x86.RCX, -1))) or_return
	append(&instructions, x86.inst_test_r64_r64(.RCX, .RDX)) or_return
	emit_branch(&instructions, &branches, .JNZ, fail) or_return
	append(&instructions, x86.inst_xor_r32_r32(.EAX, .EAX)) or_return
	append(&instructions, x86.inst_sub_r64_r64(.RAX, .R10)) or_return
	append(&instructions, x86.inst_sub_r64_r64(.RAX, .R8)) or_return
	append(&instructions, x86.inst_and_r64_r64(.RAX, .RDX)) or_return
	append(&instructions, x86.inst_add_r64_r64(.R8, .RAX)) or_return
	emit_branch(&instructions, &branches, .JC, fail) or_return
	append(&instructions, x86.inst_cmp_r64_imm32(.RCX, 8)) or_return
	emit_branch(&instructions, &branches, .JAE, sized) or_return
	append(&instructions, x86.inst_mov_r32_imm32(.ECX, 8)) or_return
	bind_branch(&targets, sized, instructions[:])
	append(&instructions, x86.inst_lea_r64_m(.RDX, x86.mem_base_disp(x86.RCX, -1))) or_return
	append(&instructions, x86.inst_mov_r64_r64(.RAX, .R8)) or_return
	append(&instructions, x86.inst_add_r64_r64(.RAX, .RDX)) or_return
	emit_branch(&instructions, &branches, .JC, fail) or_return
	append(&instructions, x86.inst_add_r64_imm32(.RAX, 48)) or_return
	emit_branch(&instructions, &branches, .JC, fail) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_base_only(x86.RSI)), .RAX)) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_base_disp(x86.RSI, 8)), .RCX)) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_base_disp(x86.RSI, 16)), .R8)) or_return
	append(&instructions, x86.inst_neg_r64(.R8)) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_base_disp(x86.RSI, 24)), .R8)) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_base_disp(x86.RSI, 32)), .R10)) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_base_disp(x86.RSI, 40)), .R9)) or_return
	append(&instructions, x86.inst_mov_r32_imm32(.EAX, 1)) or_return
	append(&instructions, x86.inst_ret_none()) or_return
	bind_branch(&targets, empty, instructions[:])
	append(&instructions, x86.inst_mov_m64_imm32(x86.mem64(x86.mem_base_only(x86.RSI)), 55)) or_return
	append(&instructions, x86.inst_mov_m64_imm32(x86.mem64(x86.mem_base_disp(x86.RSI, 8)), 8)) or_return
	append(&instructions, x86.inst_mov_m64_imm32(x86.mem64(x86.mem_base_disp(x86.RSI, 16)), 0)) or_return
	append(&instructions, x86.inst_mov_m64_imm32(x86.mem64(x86.mem_base_disp(x86.RSI, 24)), 0)) or_return
	append(&instructions, x86.inst_mov_m64_imm32(x86.mem64(x86.mem_base_disp(x86.RSI, 32)), 0)) or_return
	append(&instructions, x86.inst_mov_m64_imm32(x86.mem64(x86.mem_base_disp(x86.RSI, 40)), 0)) or_return
	append(&instructions, x86.inst_mov_r32_imm32(.EAX, 1)) or_return
	append(&instructions, x86.inst_ret_none()) or_return
	bind_branch(&targets, fail, instructions[:])
	append(&instructions, x86.inst_xor_r32_r32(.EAX, .EAX)) or_return
	append(&instructions, x86.inst_ret_none()) or_return
	return encode_branch_atom(instructions[:], branches[:], targets[:], allocator)
}

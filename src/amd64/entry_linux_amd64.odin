package amd64

import "base:runtime"
import x86 "core:rexcode/isa/x86"
import "oc:elf"
import "oc:link"

Linux_Entry_Symbols :: struct {
	main:            u32,
	init:            Maybe(u32),
	fini:            Maybe(u32),
	default_context: u32,
	args:            u32,
	argc:            u32,
	argv:            u32,
	envp:            u32,
	thread_pointer:  u32,
}

@(private = "file")
Entry_Relocation_Target :: struct {
	symbol: u32,
	kind:   elf.R_X86_64,
	addend: i64,
}

// Emits the Linux x86-64 process entry atom. All referenced symbols are supplied by the caller.
emit_linux_entry :: proc(symbols: Linux_Entry_Symbols, allocator: runtime.Allocator) -> (atom: link.Atom, err: Emit_Error) {
	labels := [?]Entry_Relocation_Target {
		{symbols.argc, .R_X86_64_PC32, -4},
		{symbols.argv, .R_X86_64_PC32, -4},
		{symbols.envp, .R_X86_64_PC32, -4},
		{symbols.args, .R_X86_64_PC32, -4},
		{symbols.args, .R_X86_64_PC32, 4},
		{symbols.thread_pointer, .R_X86_64_PC32, -4},
		{0, .R_X86_64_PLT32, -4},
		{symbols.default_context, .R_X86_64_PC32, -4},
		{symbols.main, .R_X86_64_PLT32, -4},
		{0, .R_X86_64_PLT32, -4},
	}
	instructions := make([dynamic]x86.Instruction, 0, 32, allocator) or_return
	defer delete(instructions)

	append(&instructions, x86.inst_mov_r64_m64(.RAX, x86.mem64(x86.mem_base_only(x86.RSP)))) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_rip_label(0)), .RAX)) or_return
	append(&instructions, x86.inst_lea_r64_m(.RAX, x86.mem_base_disp(x86.RSP, 8))) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_rip_label(1)), .RAX)) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_rip_label(3)), .RAX)) or_return
	append(&instructions, x86.inst_mov_r64_m64(.RCX, x86.mem64(x86.mem_base_only(x86.RSP)))) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_rip_label(4)), .RCX)) or_return
	append(&instructions, x86.inst_mov_r64_m64(.RCX, x86.mem64(x86.mem_base_only(x86.RSP)))) or_return
	append(&instructions, x86.inst_lea_r64_m(.RAX, x86.mem_base_index_disp(x86.RSP, x86.RCX, 8, 16))) or_return
	append(&instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_rip_label(2)), .RAX)) or_return
	append(&instructions, x86.inst_lea_r64_m(.RSI, x86.mem_rip_label(5))) or_return
	append(&instructions, x86.inst_mov_r32_imm32(.EDI, 0x1002)) or_return
	append(&instructions, x86.inst_mov_r32_imm32(.EAX, 158)) or_return
	append(&instructions, x86.inst_syscall_none()) or_return
	if init, ok := symbols.init.?; ok {
		labels[6].symbol = init
		append(&instructions, x86.inst_rel(.CALL, 6, 4)) or_return
	}
	append(&instructions, x86.inst_lea_r64_m(.RDI, x86.mem_rip_label(7))) or_return
	append(&instructions, x86.inst_rel(.CALL, 8, 4)) or_return
	if fini, ok := symbols.fini.?; ok {
		labels[9].symbol = fini
		append(&instructions, x86.inst_rel(.CALL, 9, 4)) or_return
	}
	append(&instructions, x86.inst_mov_r32_imm32(.EAX, 231)) or_return
	append(&instructions, x86.inst_xor_r32_r32(.EDI, .EDI)) or_return
	append(&instructions, x86.inst_syscall_none()) or_return

	label_definitions := make([]x86.Label_Definition, len(labels), allocator) or_return
	defer delete(label_definitions, allocator)
	for &definition in label_definitions { definition = x86.LABEL_UNDEFINED }
	buffer := make([]byte, len(instructions) * x86.MAX_INST_SIZE, allocator) or_return
	defer delete(buffer, allocator)
	relocations := make([dynamic]x86.Relocation, allocator) or_return
	defer delete(relocations)
	encode_errors := make([dynamic]x86.Error, allocator) or_return
	defer delete(encode_errors)
	byte_count, ok := x86.encode(instructions[:], label_definitions, buffer, &relocations, &encode_errors, resolve = false)
	if !ok || len(encode_errors) != 0 {
		return {}, Emit_Failure.Encoding_Failed
	}
	bytes := make([]byte, int(byte_count), allocator) or_return
	defer if atom.bytes == nil { delete(bytes, allocator) }
	copy(bytes, buffer[:byte_count])
	link_relocations := make([]link.Relocation, len(relocations), allocator) or_return
	defer if atom.bytes == nil { delete(link_relocations, allocator) }
	for relocation, index in relocations {
		target := labels[relocation.label_id]
		kind := target.kind
		if relocation.type != .REL32 { return {}, Emit_Failure.Encoding_Failed }
		link_relocations[index] = link.Relocation {
			offset = relocation.offset,
			symbol = target.symbol,
			kind   = kind,
			addend = target.addend,
		}
	}
	atom = link.Atom {
		section = .Text,
		align   = 16,
		bytes   = bytes,
		size    = u64(len(bytes)),
		relocs  = link_relocations,
	}
	return atom, nil
}

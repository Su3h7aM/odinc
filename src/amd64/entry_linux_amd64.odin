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
	// The `_odin_linux_tls_header` global. When present, `_start` records the
	// PT_TLS program header address there so later threads can reuse the main
	// thread's static TLS layout. Absent, the entry is byte-identical to before.
	tls_header:      Maybe(u32),
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
		{0, .R_X86_64_PC32, -4},
	}
	instructions := make([dynamic]x86.Instruction, 0, 32, allocator) or_return
	defer delete(instructions)
	branches := make([dynamic]Pending_Branch, 0, 16, allocator) or_return
	defer delete(branches)
	targets := make([dynamic]int, 0, 16, allocator) or_return
	defer delete(targets)

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
	if header, ok := symbols.tls_header.?; ok {
		labels[10].symbol = header
		emit_tls_header_scan(&instructions, &branches, &targets) or_return
	}
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

	if !resolve_branches(instructions[:], branches[:], targets[:], u32(len(labels))) {
		return {}, Emit_Failure.Encoding_Failed
	}
	label_definitions := make([]x86.Label_Definition, len(labels) + len(instructions), allocator) or_return
	defer delete(label_definitions, allocator)
	for &definition in label_definitions { definition = x86.LABEL_UNDEFINED }
	for index in 0 ..< len(instructions) {
		label_definitions[len(labels) + index] = x86.Label_Definition(u32(index))
	}
	buffer := make([]byte, len(instructions) * x86.MAX_INST_SIZE, allocator) or_return
	defer delete(buffer, allocator)
	relocations := make([dynamic]x86.Relocation, allocator) or_return
	defer delete(relocations)
	encode_errors := make([dynamic]x86.Error, allocator) or_return
	defer delete(encode_errors)
	// Resolution patches the TLS scan's local jumps in place; the remaining
	// relocations name the entry's external symbols for the linker.
	byte_count, ok := x86.encode(instructions[:], label_definitions, buffer, &relocations, &encode_errors, resolve = true)
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

// Records the PT_TLS program header address in the header global (label 10).
// Walks the auxiliary vector past envp for AT_PHDR (3), AT_PHENT (4) and
// AT_PHNUM (5), then scans the table for the first PT_TLS entry (7). Any
// missing or inconsistent table leaves the BSS zero, which the runtime reads
// as "no static TLS". Only rax, rcx, rdx and r8-r10 are touched; rsp is kept.
@(private = "file")
emit_tls_header_scan :: proc(instructions: ^[dynamic]x86.Instruction, branches: ^[dynamic]Pending_Branch, targets: ^[dynamic]int) -> Emit_Error {
	scan_env := reserve_branch(targets) or_return
	next_auxv_entry := reserve_branch(targets) or_return
	past_phdr := reserve_branch(targets) or_return
	past_phent := reserve_branch(targets) or_return
	auxv_entry := reserve_branch(targets) or_return
	headers_done := reserve_branch(targets) or_return
	next_header := reserve_branch(targets) or_return
	advance_header := reserve_branch(targets) or_return
	store_header := reserve_branch(targets) or_return
	scan_done := reserve_branch(targets) or_return

	bind_branch(targets, scan_env, instructions[:])
	append(instructions, x86.inst_cmp_m64_imm32(x86.mem64(x86.mem_base_only(x86.RAX)), 0)) or_return
	append(instructions, x86.inst_lea_r64_m(.RAX, x86.mem_base_disp(x86.RAX, 8))) or_return
	emit_branch(instructions, branches, .JNE, scan_env) or_return
	append(instructions, x86.inst_xor_r32_r32(.R8D, .R8D)) or_return
	append(instructions, x86.inst_xor_r32_r32(.R9D, .R9D)) or_return
	append(instructions, x86.inst_xor_r32_r32(.R10D, .R10D)) or_return
	append(instructions, x86.inst_xor_r32_r32(.ECX, .ECX)) or_return
	bind_branch(targets, auxv_entry, instructions[:])
	append(instructions, x86.inst_mov_r64_m64(.RDX, x86.mem64(x86.mem_base_only(x86.RAX)))) or_return
	append(instructions, x86.inst_test_r64_r64(.RDX, .RDX)) or_return
	emit_branch(instructions, branches, .JZ, headers_done) or_return
	append(instructions, x86.inst_cmp_r64_imm32(.RDX, 3)) or_return
	emit_branch(instructions, branches, .JNE, past_phdr) or_return
	append(instructions, x86.inst_mov_r64_m64(.R8, x86.mem64(x86.mem_base_disp(x86.RAX, 8)))) or_return
	bind_branch(targets, past_phdr, instructions[:])
	append(instructions, x86.inst_cmp_r64_imm32(.RDX, 4)) or_return
	emit_branch(instructions, branches, .JNE, past_phent) or_return
	append(instructions, x86.inst_mov_r64_m64(.R9, x86.mem64(x86.mem_base_disp(x86.RAX, 8)))) or_return
	bind_branch(targets, past_phent, instructions[:])
	append(instructions, x86.inst_cmp_r64_imm32(.RDX, 5)) or_return
	emit_branch(instructions, branches, .JNE, next_auxv_entry) or_return
	append(instructions, x86.inst_mov_r64_m64(.R10, x86.mem64(x86.mem_base_disp(x86.RAX, 8)))) or_return
	bind_branch(targets, next_auxv_entry, instructions[:])
	append(instructions, x86.inst_add_r64_imm32(.RAX, 16)) or_return
	emit_branch(instructions, branches, .JMP, auxv_entry) or_return
	bind_branch(targets, headers_done, instructions[:])
	append(instructions, x86.inst_test_r64_r64(.R8, .R8)) or_return
	emit_branch(instructions, branches, .JZ, scan_done) or_return
	append(instructions, x86.inst_cmp_r64_imm32(.R9, 56)) or_return
	emit_branch(instructions, branches, .JNE, scan_done) or_return
	append(instructions, x86.inst_mov_r64_r64(.RDX, .R8)) or_return
	bind_branch(targets, next_header, instructions[:])
	append(instructions, x86.inst_test_r64_r64(.R10, .R10)) or_return
	emit_branch(instructions, branches, .JZ, store_header) or_return
	append(instructions, x86.inst_cmp_m32_imm32(x86.mem32(x86.mem_base_only(x86.RDX)), 7)) or_return
	emit_branch(instructions, branches, .JNE, advance_header) or_return
	append(instructions, x86.inst_test_r64_r64(.RCX, .RCX)) or_return
	emit_branch(instructions, branches, .JNZ, scan_done) or_return
	append(instructions, x86.inst_mov_r64_r64(.RCX, .RDX)) or_return
	bind_branch(targets, advance_header, instructions[:])
	append(instructions, x86.inst_add_r64_r64(.RDX, .R9)) or_return
	emit_branch(instructions, branches, .JC, scan_done) or_return
	append(instructions, x86.inst_dec_r64(.R10)) or_return
	emit_branch(instructions, branches, .JMP, next_header) or_return
	bind_branch(targets, store_header, instructions[:])
	append(instructions, x86.inst_mov_m64_r64(x86.mem64(x86.mem_rip_label(10)), .RCX)) or_return
	bind_branch(targets, scan_done, instructions[:])
	return nil
}

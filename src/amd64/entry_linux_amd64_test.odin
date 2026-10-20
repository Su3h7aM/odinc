package amd64

import x86 "core:rexcode/isa/x86"
import "core:testing"

@(test)
linux_entry_encodes_relocations_and_preserves_call_stack_alignment :: proc(t: ^testing.T) {
	atom, emit_err := emit_linux_entry(
		Linux_Entry_Symbols{main = 18, init = 20, fini = 21, default_context = 17, args = 14, argc = 11, argv = 12, envp = 13, thread_pointer = 15},
		context.allocator,
	)
	if !testing.expect_value(t, emit_err, nil) { return }
	defer atom_destroy(&atom, context.allocator)

	instructions: [dynamic]x86.Instruction
	defer delete(instructions)
	info: [dynamic]x86.Instruction_Info
	defer delete(info)
	labels: [dynamic]x86.Label_Definition
	defer delete(labels)
	errors: [dynamic]x86.Error
	defer delete(errors)
	byte_count, decode_ok := x86.decode(atom.bytes, nil, &instructions, &info, &labels, &errors)
	if !testing.expect(t, decode_ok && len(errors) == 0 && int(byte_count) == len(atom.bytes), "entry bytes must decode completely") { return }

	call_count, syscall_count, stack_change_count := 0, 0, 0
	for instruction in instructions {
		#partial switch instruction.mnemonic {
		case .CALL:
			call_count += 1
		case .SYSCALL:
			syscall_count += 1
		case .PUSH, .POP, .ADD, .SUB:
			stack_change_count += 1
		}
	}
	testing.expect_value(t, call_count, 3)
	testing.expect_value(t, syscall_count, 2)
	testing.expect_value(t, stack_change_count, 0)

	pc_relative_count, plt_count, args_length_addend := 0, 0, false
	for relocation in atom.relocs {
		if relocation.kind == .R_X86_64_PC32 { pc_relative_count += 1 }
		if relocation.kind == .R_X86_64_PLT32 { plt_count += 1 }
		if relocation.symbol == 14 && relocation.addend == 4 { args_length_addend = true }
	}
	testing.expect_value(t, len(atom.relocs), 10)
	testing.expect_value(t, pc_relative_count, 7)
	testing.expect_value(t, plt_count, 3)
	testing.expect(t, args_length_addend, "runtime args length must address the slice length field")
}

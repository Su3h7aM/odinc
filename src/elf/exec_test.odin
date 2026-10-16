package elf

import "core:bytes"
import "core:os"
import "core:slice"
import "core:testing"

// The 10 bytes of `mov edi, 42; mov eax, 231; syscall`, i.e. the
// exit_group(42) shutdown sequence.
exit_group_42_bytes :: []byte{0xbf, 42, 0, 0, 0, 0xb8, 231, 0, 0, 0, 0x0f, 0x05}

@(test)
executable_runs_and_exits_42 :: proc(t: ^testing.T) {
	builder := executable_builder_init()
	defer executable_builder_destroy(&builder)

	text, segment_err := executable_add_segment(&builder, 0x400000, exit_group_42_bytes, 0, Program_Flags{.PF_R, .PF_X}, 0x1000)
	testing.expect(t, segment_err == nil && text != 0, "segment must be accepted")
	executable_set_entry(&builder, 0x400000)

	object, write_err := executable_write(&builder)
	testing.expect(t, write_err == nil, "write must succeed")
	testing.expect(t, len(object) == 0x1000 + len(exit_group_42_bytes), "content starts on a fresh page after header and program headers")

	header := slice.reinterpret([]File_Header, object)[0]
	testing.expect(t, header.e_type == .ET_EXEC, "e_type")
	testing.expect(t, u32(header.e_phnum) == 2, "one PT_LOAD and one PT_GNU_STACK")
	testing.expect(t, u64(header.e_entry) == 0x400000, "entry")
	testing.expect(t, u64(header.e_phoff) == 64, "program headers follow the header")
	testing.expect(t, u32(header.e_shnum) == 0 && u64(header.e_shoff) == 0, "no section headers")

	program_headers := slice.reinterpret([]Program_Header, object[header.e_phoff:])
	text_header := program_headers[0]
	testing.expect(t, u32(text_header.p_type) == PT_LOAD, "PT_LOAD")
	testing.expect(t, u64(text_header.p_vaddr) == 0x400000, "text vaddr")
	testing.expect(t, u64(text_header.p_filesz) == u64(len(exit_group_42_bytes)), "text filesz")
	testing.expect(t, u64(text_header.p_memsz) == u64(len(exit_group_42_bytes)), "text memsz")
	testing.expect(t, (u32(text_header.p_flags) & 1) != 0, "text is executable")
	testing.expect(t, (u32(text_header.p_flags) & 2) == 0, "text is not writable")
	testing.expect(t, u64(text_header.p_align) == 0x1000, "alignment")
	testing.expect(t, (u64(text_header.p_offset) - u64(text_header.p_vaddr)) % u64(text_header.p_align) == 0, "offset congruent to vaddr")

	stack_header := program_headers[1]
	testing.expect(t, u32(stack_header.p_type) == PT_GNU_STACK, "PT_GNU_STACK")
	testing.expect(t, u32(stack_header.p_flags) == 6, "stack readable and writable")
	testing.expect(t, (u32(stack_header.p_flags) & 1) == 0, "stack not executable")

	testing.expect(t, bytes.equal(bytes_at(object, int(u64(text_header.p_offset)), len(exit_group_42_bytes)), exit_group_42_bytes), "segment bytes written")

	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	testing.expect(t, os.write_entire_file("/tmp/opencode/elf-exec", object, permissions) == nil, "executable written")
	delete(object, context.allocator)

	process, process_err := os.process_start(os.Process_Desc{command = []string{"/tmp/opencode/elf-exec"}})
	testing.expect(t, process_err == nil, "process must start")
	state, wait_err := os.process_wait(process)
	testing.expect(t, wait_err == nil, "process must be waited on")
	// This fork's `Process_State.success` means exit code zero, so a
	// deliberate `exit_group(42)` is asserted through `exited` directly.
	testing.expect(t, state.exited && state.exit_code == 42, "process exits 42")
	testing.expect(t, state.exit_code == 42, "exit_group(42)")
}

bytes_at :: proc "contextless" (data: []byte, offset: int, length: int) -> []byte {
	return data[offset:offset + length]
}


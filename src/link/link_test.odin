package link

import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"

process_lock: sync.Mutex

write_executable :: proc(path: string, image: []byte) -> os.Error {
	sync.mutex_lock(&process_lock)
	defer sync.mutex_unlock(&process_lock)
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	return os.write_entire_file(path, image, permissions)
}

start_process :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
	sync.mutex_lock(&process_lock)
	defer sync.mutex_unlock(&process_lock)
	return os.process_start(desc)
}

run_executable_expect_exit :: proc(t: ^testing.T, image: []byte, expected_code: int) {
	directory, dir_err := os.make_directory_temp("", "link-l1-*", context.temp_allocator)
	if !testing.expect(t, dir_err == nil, "temporary directory must be created") { return }
	defer os.remove_all(directory)
	executable_path, path_err := filepath.join({directory, "exit"}, context.temp_allocator)
	testing.expect(t, path_err == nil, "executable path must be joined")

	testing.expect(t, write_executable(executable_path, image) == nil, "executable must be written")

	devnull, devnull_err := os.open("/dev/null", {.Write})
	testing.expect(t, devnull_err == nil, "devnull must open")
	defer _ = os.close(devnull)
	process, start_err := start_process(os.Process_Desc{command = []string{executable_path}, stdout = devnull, stderr = devnull})
	testing.expect(t, start_err == nil, "process must start")
	state, wait_err := os.process_wait(process)
	testing.expect(t, wait_err == nil, "process must be waited on")
	testing.expect(t, state.exited && state.exit_code == expected_code, "process must exit with the expected code")
}

@(test)
call_and_data_load_exit_with_seven :: proc(t: ^testing.T) {
	start_code := [?]byte{0xe8, 0, 0, 0, 0, 0xb8, 231, 0, 0, 0, 0x0f, 0x05} // call callee; mov eax, 231; syscall
	callee_code := [?]byte{0x8b, 0x3d, 0, 0, 0, 0, 0xc3} // mov edi, [rip + data]; ret
	data_bytes := [?]byte{7, 0, 0, 0}
	start_relocs := []Relocation{{offset = 1, symbol = 1, kind = .R_X86_64_PLT32, addend = -4}}
	callee_relocs := []Relocation{{offset = 2, symbol = 2, kind = .R_X86_64_PC32, addend = -4}}
	atoms := []Atom {
		{section = .Text, align = 16, bytes = start_code[:], size = u64(len(start_code)), relocs = start_relocs},
		{section = .Text, align = 16, bytes = callee_code[:], size = u64(len(callee_code)), relocs = callee_relocs},
		{section = .Data, align = 4, bytes = data_bytes[:], size = u64(len(data_bytes))},
	}
	symbols := []Symbol{{name = "_start", atom = 0}, {name = "callee", atom = 1}, {name = "data", atom = 2}}

	image, link_err := link([]Input{{atoms = atoms, symbols = symbols}}, "_start", context.allocator)
	testing.expect(t, link_err == nil, "link must succeed")
	defer delete(image, context.allocator)
	run_executable_expect_exit(t, image, 7)
}

@(test)
tls_variable_through_fs_exits_with_seven :: proc(t: ^testing.T) {
	start_code := [?]byte {
		0xbf,
		0x02,
		0x10,
		0,
		0, // mov edi, ARCH_SET_FS
		0xbe,
		0,
		0,
		0,
		0, // mov esi, imm32 (&tls_var + 8, the TLS block end)
		0xb8,
		158,
		0,
		0,
		0, // mov eax, SYS_arch_prctl
		0x0f,
		0x05, // syscall
		0x64,
		0x8b,
		0x04,
		0x25,
		0,
		0,
		0,
		0, // mov eax, fs:[tpoff32(tls_var)]
		0x89,
		0xc7, // mov edi, eax
		0xb8,
		231,
		0,
		0,
		0, // mov eax, SYS_exit_group
		0x0f,
		0x05, // syscall
	}
	tls_bytes := [?]byte{7, 0, 0, 0, 0, 0, 0, 0}
	start_relocs := []Relocation{{offset = 6, symbol = 1, kind = .R_X86_64_32, addend = 8}, {offset = 21, symbol = 1, kind = .R_X86_64_TPOFF32}}
	text_symbols := []Symbol{{name = "_start", atom = 0}, {name = "tls_var", atom = ATOM_UNDEFINED}}
	atoms := []Atom{{section = .Text, align = 16, bytes = start_code[:], size = u64(len(start_code)), relocs = start_relocs}}
	tls_atoms := []Atom{{section = .Tdata, align = 8, bytes = tls_bytes[:], size = u64(len(tls_bytes))}}
	tls_symbols := []Symbol{{name = "tls_var", atom = 0}}

	inputs := []Input{{atoms = atoms, symbols = text_symbols}, {atoms = tls_atoms, symbols = tls_symbols}}
	image, link_err := link(inputs, "_start", context.allocator)
	testing.expect(t, link_err == nil, "link must succeed across two inputs")
	defer delete(image, context.allocator)
	run_executable_expect_exit(t, image, 7)
}

@(test)
pc32_beyond_i32_range_is_overflow :: proc(t: ^testing.T) {
	code := [?]byte{0xe8, 0, 0, 0, 0, 0xc3} // call far
	relocs := []Relocation{{offset = 1, symbol = 1, kind = .R_X86_64_PC32, addend = -4}}
	atoms := []Atom {
		{section = .Text, align = 16, bytes = code[:], size = u64(len(code)), relocs = relocs},
		{section = .Bss, align = 16, size = 1 << 31}, // reserves 2 GiB of address space before the target
		{section = .Bss, align = 16, size = 8},
	}
	symbols := []Symbol{{name = "_start", atom = 0}, {name = "far", atom = 2}}

	image, err := link([]Input{{atoms = atoms, symbols = symbols}}, "_start", context.allocator)
	defer delete(image, context.allocator)
	_, is_overflow := err.(Relocation_Overflow)
	testing.expect(t, is_overflow, "PC32 beyond i32 must be Relocation_Overflow")
}

package amd64

import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:sync"
import "core:testing"
import "oc:ir"
import "oc:link"
import "oc:regalloc"

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

// `add(a, b)` built by hand, allocated and emitted, then linked behind a `_start` that
// calls `add(3, 4)` and exits with the result. `llvm-objdump -d` of the function atom:
//
//	push rbp
//	mov  rbp, rsp
//	add  rdi, rsi
//	mov  rax, rdi
//	pop  rbp
//	ret
@(test)
emitted_add_links_and_exits_with_seven :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	signature := ir.Signature {
		cc      = .C,
		params  = []ir.Param{{type = .I64}, {type = .I64}},
		results = []ir.Result{{type = .I64}},
	}
	assignment, abi_err := assign_signature(signature, allocator)
	testing.expect_value(t, abi_err, nil)

	function: Machine_Function
	testing.expect_value(t, machine_function_init(&function, "add"), nil)
	defer machine_function_destroy(&function)
	block, _ := add_block(&function)
	params, start_err := lower_start(&function, block, signature, assignment, allocator)
	testing.expect_value(t, start_err, nil)
	sum, _ := new_vreg(&function, .Int)
	testing.expect_value(t, emit(&function, block, .ADD, 8, sum, params[0], params[1]), nil)
	testing.expect_value(t, lower_return(&function, block, signature, assignment, params, []Vreg{sum}, allocator), nil)
	testing.expect_value(t, verify_machine(&function), Verify_Error{})

	program, program_err := build_program(&function, allocator)
	testing.expect_value(t, program_err, nil)
	result, allocation_err := regalloc.allocate(&program)
	defer regalloc.result_destroy(&result)
	testing.expect_value(t, allocation_err.kind, regalloc.Allocation_Error.None)

	atom, emit_err := emit_function(&function, &result, {}, context.allocator)
	testing.expect_value(t, emit_err, nil)
	defer atom_destroy(&atom, context.allocator)
	testing.expect(t, len(atom.bytes) >= 6 && atom.bytes[0] == 0x55 && atom.bytes[len(atom.bytes) - 1] == 0xc3, "framed function")
	testing.expect_value(t, len(atom.relocs), 0)

	start_code := [?]byte{0xbf, 3, 0, 0, 0, 0xbe, 4, 0, 0, 0, 0xe8, 0, 0, 0, 0, 0x89, 0xc7, 0xb8, 231, 0, 0, 0, 0x0f, 0x05}
	start_relocs := []link.Relocation{{offset = 11, symbol = 1, kind = .R_X86_64_PLT32, addend = -4}}
	atoms := []link.Atom{{section = .Text, align = 16, bytes = start_code[:], size = len(start_code), relocs = start_relocs}, atom}
	symbols := []link.Symbol{{name = "_start", atom = 0}, {name = "add", atom = 1}}
	image, link_err := link.link([]link.Input{{atoms = atoms, symbols = symbols}}, "_start", context.allocator)
	testing.expect(t, link_err == nil, "link must succeed")
	defer delete(image)

	directory, directory_err := os.make_directory_temp("", "amd64-emit-*", context.temp_allocator)
	testing.expect(t, directory_err == nil, "temporary directory must be created")
	path, _ := filepath.join({directory, "add"}, context.temp_allocator)
	defer {
		testing.expect(t, os.remove(path) == nil, "executable must be removed")
		testing.expect(t, os.remove(directory) == nil, "temporary directory must be removed")
	}
	testing.expect(t, write_executable(path, image) == nil, "executable must be written")
	devnull, devnull_err := os.open("/dev/null", {.Write})
	testing.expect(t, devnull_err == nil, "devnull must open")
	defer _ = os.close(devnull)
	process, process_err := start_process(os.Process_Desc{command = []string{path}, stdout = devnull, stderr = devnull})
	testing.expect(t, process_err == nil, "process must start")
	state, wait_err := os.process_wait(process)
	testing.expect(t, wait_err == nil, "process must be waited on")
	testing.expect_value(t, state.exit_code, 7)
}
@(test)
emitted_shift_by_immediate_uses_imm8_form :: proc(t: ^testing.T) {
	// The 64-bit shift by 1 comes first, so a cached shift-by-1 form would be reused for the 56.
	shift_by_one_64 := [?]byte{0x55, 0x48, 0x89, 0xe5, 0x48, 0xc1, 0xef, 0x01, 0x48, 0x89, 0xf8, 0x5d, 0xc3}
	shift_by_56_64 := [?]byte{0x55, 0x48, 0x89, 0xe5, 0x48, 0xc1, 0xef, 0x38, 0x48, 0x89, 0xf8, 0x5d, 0xc3}
	shift_by_5_32 := [?]byte{0x55, 0x48, 0x89, 0xe5, 0xc1, 0xef, 0x05, 0x48, 0x89, 0xf8, 0x5d, 0xc3}
	shift_by_3_16 := [?]byte{0x55, 0x48, 0x89, 0xe5, 0x66, 0xc1, 0xef, 0x03, 0x48, 0x89, 0xf8, 0x5d, 0xc3}
	shift_by_7_8 := [?]byte{0x55, 0x48, 0x89, 0xe5, 0x40, 0xc0, 0xef, 0x07, 0x48, 0x89, 0xf8, 0x5d, 0xc3}
	expect_emitted_shift(t, 8, 1, shift_by_one_64[:])
	expect_emitted_shift(t, 8, 56, shift_by_56_64[:])
	expect_emitted_shift(t, 4, 5, shift_by_5_32[:])
	expect_emitted_shift(t, 2, 3, shift_by_3_16[:])
	expect_emitted_shift(t, 1, 7, shift_by_7_8[:])
}

@(private = "file")
expect_emitted_shift :: proc(t: ^testing.T, width: u8, count: i64, expected: []byte) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	signature := ir.Signature {
		cc      = .C,
		params  = []ir.Param{{type = .I64}},
		results = []ir.Result{{type = .I64}},
	}
	assignment, abi_err := assign_signature(signature, allocator)
	testing.expect_value(t, abi_err, nil)

	function: Machine_Function
	testing.expect_value(t, machine_function_init(&function, "shift"), nil)
	defer machine_function_destroy(&function)
	block, _ := add_block(&function)
	params, start_err := lower_start(&function, block, signature, assignment, allocator)
	testing.expect_value(t, start_err, nil)
	input := params[0].(Vreg)
	shifted, _ := new_vreg(&function, .Int)
	testing.expect_value(t, emit(&function, block, .SHR, width, shifted, input, Immediate(count)), nil)
	testing.expect_value(t, lower_return(&function, block, signature, assignment, params, []Vreg{shifted}, allocator), nil)
	testing.expect_value(t, verify_machine(&function), Verify_Error{})

	program, program_err := build_program(&function, allocator)
	testing.expect_value(t, program_err, nil)
	result, allocation_err := regalloc.allocate(&program)
	defer regalloc.result_destroy(&result)
	testing.expect_value(t, allocation_err.kind, regalloc.Allocation_Error.None)

	atom, emit_err := emit_function(&function, &result, {}, context.allocator)
	testing.expect_value(t, emit_err, nil)
	defer atom_destroy(&atom, context.allocator)
	testing.expectf(t, slice.equal(atom.bytes, expected), "width %v count %v emitted % x", width, count, atom.bytes)
}

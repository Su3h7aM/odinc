package amd64

import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "oc:ir"
import "oc:link"
import "oc:regalloc"

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
	permissions := os.Permissions_Read_All + os.Permissions{.Write_User, .Execute_User}
	testing.expect(t, os.write_entire_file(path, image, permissions) == nil, "executable must be written")
	process, process_err := os.process_start(os.Process_Desc{command = []string{path}})
	testing.expect(t, process_err == nil, "process must start")
	state, wait_err := os.process_wait(process)
	testing.expect(t, wait_err == nil, "process must be waited on")
	testing.expect_value(t, state.exit_code, 7)
}

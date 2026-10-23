package amd64

import "core:mem/virtual"
import x86 "core:rexcode/isa/x86"
import "core:strings"
import "core:testing"
import "oc:ir"
import "oc:regalloc"

@(test)
atomic_encodings_preserve_width_lock_and_retry :: proc(t: ^testing.T) {
	widths := [?]u8{1, 2, 4, 8}
	mnemonics := [?]x86.Mnemonic{.XADD, .XCHG, .CMPXCHG, .AND, .OR, .XOR, .NOT}
	for width in widths {
		for mnemonic in mnemonics {
			function: Machine_Function
			if !testing.expect_value(t, machine_function_init(&function, "atomic"), nil) { return }
			block, _ := add_block(&function)
			address, _ := new_vreg(&function, .Int)
			accumulator, _ := new_vreg(&function, .Int)
			value, _ := new_vreg(&function, .Int)
			temporary, _ := new_vreg(&function, .Int)
			operands := [?]Machine_Operand{Memory_Ref{base = address}, fixed(accumulator, gpr(.RAX), .Use_Def), value, fixed(temporary, gpr(.RDX), .Use_Def)}
			if mnemonic == .AND || mnemonic == .OR || mnemonic == .XOR || mnemonic == .NOT { operands[2] = fixed(value, gpr(.RCX), .Use) }
			testing.expect_value(
				t,
				emit_instruction(&function, block, Machine_Instruction{pseudo = .Atomic, mnemonic = mnemonic, width = width, operands = operands[:]}),
				nil,
			)
			testing.expect_value(t, emit(&function, block, .MFENCE, 0), nil)
			testing.expect_value(t, emit_pseudo(&function, block, .Return), nil)
			testing.expect_value(t, verify_machine(&function), Verify_Error{})
			locations := [?]regalloc.Location{gpr(.RDI), gpr(.RAX), gpr(.RCX), gpr(.RDX)}
			allocation := regalloc.Result {
				location = locations[:],
			}
			atom, err := emit_function(&function, &allocation, {}, context.allocator)
			if !testing.expect_value(t, err, nil) { continue }
			defer atom_destroy(&atom, context.allocator)
			code := string(atom.bytes)
			testing.expect(t, strings.contains(code, "\x0f\xae\xf0"), "seq_cst fence must encode mfence")
			opcode := byte(0xb0 if width == 1 else 0xb1)
			mod_rm := byte(0x17)
			if mnemonic == .XADD {
				opcode = 0xc0 if width == 1 else 0xc1
				mod_rm = 0x07
			} else if mnemonic == .CMPXCHG {
				mod_rm = 0x0f
			}
			expected: [5]byte
			length := 0
			if mnemonic != .XCHG {
				expected[length] = 0xf0
				length += 1
			}
			if width == 2 || width == 8 {
				expected[length] = 0x66 if width == 2 else 0x48
				length += 1
			}
			if mnemonic == .XCHG {
				expected[length], expected[length + 1] = 0x86 if width == 1 else 0x87, 0x07
				length += 2
			} else {
				expected[length], expected[length + 1], expected[length + 2] = 0x0f, opcode, mod_rm
				length += 3
			}
			testing.expectf(t, strings.contains(code, string(expected[:length])), "%v width %d must encode its prefixes and memory opcode", mnemonic, width)
			if mnemonic == .AND || mnemonic == .OR || mnemonic == .XOR || mnemonic == .NOT {
				retry := false
				for index in 0 ..< len(atom.bytes) - 1 {
					if atom.bytes[index] == 0x75 && atom.bytes[index + 1] >= 0x80 { retry = true }
				}
				testing.expect(t, retry, "bitwise result must retry cmpxchg after failure")
			}
		}
	}
}

@(test)
bitwise_atomic_preserves_inputs_from_scratch_registers :: proc(t: ^testing.T) {
	registers := [?]Gpr{.RAX, .RDX}
	for register in registers {
		arena: virtual.Arena
		if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
		defer virtual.arena_destroy(&arena)
		allocator := virtual.arena_allocator(&arena)
		input, input_error := ir.function_make(context.allocator, 0, "atomic", 0)
		if !testing.expect_value(t, input_error, nil) { return }
		defer ir.function_destroy(input)
		ir.add_signature(input, ir.Signature{cc = .C, params = []ir.Param{{type = .Ptr}, {type = .I64}}})
		entry := ir.start(input)
		address_node, value_node := entry.params[0], entry.params[1]
		atomic := ir.add_node(input, .Atomic_Rmw, .Tuple, {entry.control, entry.memory, address_node, value_node}, {access = {order = .Seq_Cst, rmw = .And}})
		function: Machine_Function
		if !testing.expect_value(t, machine_function_init(&function, "atomic"), nil) { return }
		block, _ := add_block(&function)
		address, _ := new_vreg(&function, .Int)
		value, _ := new_vreg(&function, .Int)
		testing.expect_value(t, emit_pseudo(&function, block, .Entry, fixed(address, gpr(.RDI), .Def), fixed(value, gpr(register), .Def)), nil)
		values := make([]Vreg, len(input.nodes), allocator)
		tuples := make([][]Vreg, len(input.nodes), allocator)
		address_parts := make([]Address_Parts, len(input.nodes), allocator)
		address_ready := make([]bool, len(input.nodes), allocator)
		values[address_node], values[value_node] = address, value
		selector := Selector {
			input         = input,
			output        = &function,
			allocator     = allocator,
			values        = values,
			tuples        = tuples,
			address_parts = address_parts,
			address_ready = address_ready,
			block         = block,
		}
		if !testing.expect_value(t, select_atomic(&selector, atomic), nil) { return }
		testing.expect_value(t, emit_pseudo(&function, block, .Return), nil)
		testing.expect_value(t, verify_machine(&function), Verify_Error{})
		program, program_error := build_program(&function, allocator)
		if !testing.expect_value(t, program_error, nil) { return }
		allocation, allocation_error := regalloc.allocate(&program)
		defer regalloc.result_destroy(&allocation)
		if !testing.expect_value(t, allocation_error.kind, regalloc.Allocation_Error.None) { continue }
		testing.expect_value(t, allocation.location[value], regalloc.Location(gpr(register)))
		for instruction in function.blocks[block].instructions {
			if instruction.pseudo != .Atomic { continue }
			preserved, ok := instruction.operands[2].(Fixed_Vreg)
			if testing.expect(t, ok, "bitwise input must have its own fixed register") {
				testing.expect_value(t, preserved.register, gpr(.RCX))
				testing.expect_value(t, allocation.location[preserved.vreg], regalloc.Location(gpr(.RCX)))
			}
		}
		atom, emit_error := emit_function(&function, &allocation, {}, context.allocator)
		if !testing.expect_value(t, emit_error, nil) { continue }
		defer atom_destroy(&atom, context.allocator)
		code := string(atom.bytes)
		testing.expect(
			t,
			strings.contains(code, "\x48\x21\xca") || strings.contains(code, "\x48\x23\xd1"),
			"retry loop must read RCX, not the overwritten source register",
		)
	}
}

package amd64

import "base:runtime"
import "core:mem"
import x86 "core:rexcode/isa/x86"
import "oc:regalloc"

// A spill slot is wide enough for a `V128` value, which is the widest a register holds.
SPILL_SLOT_BYTES :: 16
PROBE_PAGE_BYTES :: 4096
MAX_FRAME_ALIGNMENT :: 16
CALLEE_SAVED_ORDER :: [?]Gpr{.RBX, .R12, .R13, .R14, .R15}

// Frame_Layout is a pure function of the machine function and the allocation. Offsets
// are relative to `rbp`; below the saved `rbp` come the pushed callee-saved registers,
// the `Slot` objects in index order, the spill slots, and the outgoing argument area at `rsp`.
Frame_Layout :: struct {
	saved:                       [len(CALLEE_SAVED_ORDER)]Gpr,
	saved_count:                 int,
	slot_offsets:                []i32,
	spill_start:                 i32,
	frame_bytes:                 u32,
	// restores_from_frame_pointer says the body moves rsp (Stack_Alloc), so the epilogue derives the saved-register
	// base from rbp; otherwise the epilogue adds back frame_bytes.
	restores_from_frame_pointer: bool,
	// uses_frame_pointer is false when nothing in the body addresses through rbp and rsp never moves,
	// so the prologue and epilogue skip the rbp chain and address everything from rsp.
	uses_frame_pointer:          bool,
}

frame_layout :: proc(function: ^Machine_Function, result: ^regalloc.Result, allocator: mem.Allocator) -> (layout: Frame_Layout, err: Emit_Error) {
	for register in CALLEE_SAVED_ORDER {
		if int(register) in result.callee_saved_used[.Int] {
			layout.saved[layout.saved_count] = register
			layout.saved_count += 1
		}
	}
	layout.slot_offsets = make([]i32, len(function.frame_slots), allocator) or_return
	cursor := u32(8 * layout.saved_count)
	layout.restores_from_frame_pointer = moves_stack_pointer(function)
	needs_rbp, has_calls := scan_frame_uses(function)
	layout.uses_frame_pointer = layout.restores_from_frame_pointer || len(function.frame_slots) > 0 || result.spill_slot_count > 0 || needs_rbp
	if !layout.uses_frame_pointer {
		cursor += 8
	}
	for slot, index in function.frame_slots {
		if slot.align > MAX_FRAME_ALIGNMENT {
			return {}, Emit_Failure.Unsupported_Alignment
		}
		cursor = align_up(cursor + slot.size, max(slot.align, 1))
		layout.slot_offsets[index] = -i32(cursor)
	}
	layout.spill_start = -i32(cursor + SPILL_SLOT_BYTES)
	cursor += SPILL_SLOT_BYTES * result.spill_slot_count
	total := cursor + function.outgoing_bytes
	if has_calls || function.outgoing_bytes > 0 {
		total = align_up(total, 16)
	}
	layout.frame_bytes = total - u32(8 * layout.saved_count)
	if !layout.uses_frame_pointer {
		layout.frame_bytes -= 8
	}
	return layout, nil
}

spill_offset :: proc(layout: Frame_Layout, slot: regalloc.Spill_Slot) -> i32 {
	return layout.spill_start - SPILL_SLOT_BYTES * i32(slot)
}

emit_prologue :: proc(instructions: ^[dynamic]x86.Instruction, layout: Frame_Layout) -> runtime.Allocator_Error {
	if layout.uses_frame_pointer {
		append(instructions, x86.inst_r(.PUSH, x86.RBP)) or_return
		append(instructions, x86.inst_r_r(.MOV, x86.RBP, x86.RSP)) or_return
	}
	for index in 0 ..< layout.saved_count {
		append(instructions, x86.inst_r(.PUSH, x86.gpr64_from_num(u8(layout.saved[index])))) or_return
	}
	remaining := layout.frame_bytes
	for remaining >= PROBE_PAGE_BYTES {
		append(instructions, x86.inst_r_i(.SUB, x86.RSP, PROBE_PAGE_BYTES, 4)) or_return
		append(instructions, x86.inst_m_i(.OR, x86.mem_base_only(x86.RSP), 8, 0, 1)) or_return
		remaining -= PROBE_PAGE_BYTES
	}
	if remaining > 0 {
		append(instructions, x86.inst_r_i(.SUB, x86.RSP, i64(remaining), 4)) or_return
	}
	return nil
}

emit_epilogue :: proc(instructions: ^[dynamic]x86.Instruction, layout: Frame_Layout) -> runtime.Allocator_Error {
	if layout.restores_from_frame_pointer {
		if layout.saved_count > 0 {
			restore := x86.mem_base_disp(x86.RBP, -i32(8 * layout.saved_count))
			append(instructions, x86.inst_r_m(.LEA, x86.RSP, restore, 8)) or_return
		} else {
			append(instructions, x86.inst_r_r(.MOV, x86.RSP, x86.RBP)) or_return
		}
	} else if layout.frame_bytes > 0 {
		append(instructions, x86.inst_r_i(.ADD, x86.RSP, i64(layout.frame_bytes), 4)) or_return
	}
	for index := layout.saved_count - 1; index >= 0; index -= 1 {
		append(instructions, x86.inst_r(.POP, x86.gpr64_from_num(u8(layout.saved[index])))) or_return
	}
	if layout.uses_frame_pointer {
		append(instructions, x86.inst_r(.POP, x86.RBP)) or_return
	}
	append(instructions, x86.inst_none(.RET)) or_return
	return nil
}

// prologue_sub_count mirrors the stack-probe loop in emit_prologue: two instructions
// per probed page, plus one for a nonzero remainder.
@(private)
prologue_sub_count :: proc(frame_bytes: u32) -> int {
	count := 0
	remaining := frame_bytes
	for remaining >= PROBE_PAGE_BYTES {
		count += 2
		remaining -= PROBE_PAGE_BYTES
	}
	if remaining > 0 {
		count += 1
	}
	return count
}

// Stack_Alloc (`intrinsics.alloca`) moves rsp inside the body, which the frame size does not show.
@(private = "file")
moves_stack_pointer :: proc(function: ^Machine_Function) -> bool {
	for &block in function.blocks {
		for &instruction in block.instructions {
			for operand in instruction.operands {
				if register, is_physical := operand.(Physical_Register); is_physical && Gpr(register) == .RSP {
					return true
				}
			}
		}
	}
	return false
}

// scan_frame_uses reports what the body needs from the frame: rbp-relative addressing
// (a Slot, Spill or Incoming frame object, or rbp itself; Outgoing objects address
// through rsp) and whether it calls (which alone requires 16-byte stack alignment).
@(private = "file")
scan_frame_uses :: proc(function: ^Machine_Function) -> (needs_rbp, has_calls: bool) {
	for &block in function.blocks {
		for &instruction in block.instructions {
			if instruction.pseudo == .Call {
				has_calls = true
			}
			for operand in instruction.operands {
				switch value in operand {
				case Physical_Register:
					if Gpr(value) == .RBP {
						needs_rbp = true
					}
				case Fixed_Vreg:
					if value.register == gpr(.RBP) {
						needs_rbp = true
					}
				case Memory_Ref:
					if object, is_object := value.base.(Frame_Object); is_object {
						switch object.kind {
						case .Slot, .Spill, .Incoming:
							needs_rbp = true
						case .Outgoing:
						}
					}
				case Vreg, Immediate, Block_Ref, Symbol_Target, Thread_Pointer_Offset:
				}
			}
		}
	}
	return needs_rbp, has_calls
}

@(private = "file")
align_up :: proc(value, alignment: u32) -> u32 {
	return (value + alignment - 1) & ~(alignment - 1)
}

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
	saved:        [len(CALLEE_SAVED_ORDER)]Gpr,
	saved_count:  int,
	slot_offsets: []i32,
	spill_start:  i32,
	frame_bytes:  u32,
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
	for slot, index in function.frame_slots {
		if slot.align > MAX_FRAME_ALIGNMENT {
			return {}, Emit_Failure.Unsupported_Alignment
		}
		cursor = align_up(cursor + slot.size, max(slot.align, 1))
		layout.slot_offsets[index] = -i32(cursor)
	}
	layout.spill_start = -i32(cursor + SPILL_SLOT_BYTES)
	cursor += SPILL_SLOT_BYTES * result.spill_slot_count
	total := align_up(cursor + function.outgoing_bytes, 16)
	layout.frame_bytes = total - u32(8 * layout.saved_count)
	return layout, nil
}

spill_offset :: proc(layout: Frame_Layout, slot: regalloc.Spill_Slot) -> i32 {
	return layout.spill_start - SPILL_SLOT_BYTES * i32(slot)
}

emit_prologue :: proc(instructions: ^[dynamic]x86.Instruction, layout: Frame_Layout) -> runtime.Allocator_Error {
	append(instructions, x86.inst_r(.PUSH, x86.RBP)) or_return
	append(instructions, x86.inst_r_r(.MOV, x86.RBP, x86.RSP)) or_return
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
	if layout.saved_count > 0 {
		restore := x86.mem_base_disp(x86.RBP, -i32(8 * layout.saved_count))
		append(instructions, x86.inst_r_m(.LEA, x86.RSP, restore, 8)) or_return
		for index := layout.saved_count - 1; index >= 0; index -= 1 {
			append(instructions, x86.inst_r(.POP, x86.gpr64_from_num(u8(layout.saved[index])))) or_return
		}
	} else if layout.frame_bytes > 0 {
		append(instructions, x86.inst_r_r(.MOV, x86.RSP, x86.RBP)) or_return
	}
	append(instructions, x86.inst_r(.POP, x86.RBP)) or_return
	append(instructions, x86.inst_none(.RET)) or_return
	return nil
}

@(private = "file")
align_up :: proc(value, alignment: u32) -> u32 {
	return (value + alignment - 1) & ~(alignment - 1)
}

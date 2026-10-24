package amd64

import "base:runtime"
import "core:mem"

// DWARF 6.4.2; AMD64 psABI register numbers differ from the instruction encoding.
@(private = "file")
unwind_register :: proc(register: Gpr) -> byte {
	#partial switch register {
	case .RBX:
		return 3
	case .R12:
		return 12
	case .R13:
		return 13
	case .R14:
		return 14
	case .R15:
		return 15
	case:
		unreachable()
	}
}

@(private = "file")
unwind_advance :: proc(bytes: ^[dynamic]byte, previous: ^u32, offset: u32) -> runtime.Allocator_Error {
	delta := offset - previous^
	if delta > 0 {
		switch {
		case delta < 64:
			append(bytes, 0x40 | byte(delta)) or_return
		case delta <= 0xff:
			append(bytes, 0x02, byte(delta)) or_return
		case delta <= 0xffff:
			append(bytes, 0x03, byte(delta), byte(delta >> 8)) or_return
		case:
			append(bytes, 0x04, byte(delta), byte(delta >> 8), byte(delta >> 16), byte(delta >> 24)) or_return
		}
		previous^ = offset
	}
	return nil
}

// append_uleb appends an unsigned LEB128 value, for CFA offsets that do not fit one byte.
@(private = "file")
append_uleb :: proc(bytes: ^[dynamic]byte, value: u32) -> runtime.Allocator_Error {
	remaining := value
	for remaining >= 0x80 {
		append(bytes, byte(remaining) | 0x80) or_return
		remaining >>= 7
	}
	append(bytes, byte(remaining)) or_return
	return nil
}

@(private)
emit_frame_unwind :: proc(layout: Frame_Layout, offsets: []u32, has_return: bool, allocator: mem.Allocator) -> (bytes: []byte, err: runtime.Allocator_Error) {
	instructions := make([dynamic]byte, 0, 0, context.temp_allocator) or_return
	defer delete(instructions)
	previous: u32
	if !layout.uses_frame_pointer {
		emit_frameless_unwind(&instructions, &previous, layout, offsets, has_return) or_return
	} else {
		emit_framed_unwind(&instructions, &previous, layout, offsets, has_return) or_return
	}
	bytes = make([]byte, len(instructions), allocator) or_return
	copy(bytes, instructions[:])
	return
}

@(private = "file")
emit_framed_unwind :: proc(bytes: ^[dynamic]byte, previous: ^u32, layout: Frame_Layout, offsets: []u32, has_return: bool) -> runtime.Allocator_Error {
	unwind_advance(bytes, previous, offsets[1]) or_return
	append(bytes, 0x0e, 16, 0x86, 2) or_return // CFA=rsp+16; rbp at CFA-16.
	unwind_advance(bytes, previous, offsets[2]) or_return
	append(bytes, 0x0d, 6) or_return // CFA=rbp+16, including dynamic stack allocation.
	for index in 0 ..< layout.saved_count {
		unwind_advance(bytes, previous, offsets[3 + index]) or_return
		append(bytes, 0x80 | unwind_register(layout.saved[index]), byte(3 + index)) or_return
	}
	if has_return {
		pop_first := (len(offsets) - 1) - layout.saved_count - 2
		for index in 0 ..< layout.saved_count {
			unwind_advance(bytes, previous, offsets[pop_first + index + 1]) or_return
			register := layout.saved[layout.saved_count - index - 1]
			append(bytes, 0xc0 | unwind_register(register)) or_return
		}
		unwind_advance(bytes, previous, offsets[(len(offsets) - 1) - 1]) or_return
		append(bytes, 0x0c, 7, 8, 0xc6) or_return // After pop rbp, CFA=rsp+8.
	}
	return nil
}

// emit_frameless_unwind describes a prologue of pushed callee-saved registers and an
// optional stack subtraction, with CFA tracked from rsp throughout. A rule at offsets[i]
// describes the state after prologue instruction i-1, mirroring emit_framed_unwind.
@(private = "file")
emit_frameless_unwind :: proc(bytes: ^[dynamic]byte, previous: ^u32, layout: Frame_Layout, offsets: []u32, has_return: bool) -> runtime.Allocator_Error {
	for index in 0 ..< layout.saved_count {
		unwind_advance(bytes, previous, offsets[1 + index]) or_return
		append(bytes, 0x0e) or_return
		append_uleb(bytes, 16 + u32(8 * index)) or_return // CFA=rsp+16 after this push.
		append(bytes, 0x80 | unwind_register(layout.saved[index]), byte(2 + index)) or_return
	}
	subs := prologue_sub_count(layout.frame_bytes)
	if layout.frame_bytes > 0 {
		unwind_advance(bytes, previous, offsets[layout.saved_count + subs]) or_return
		append(bytes, 0x0e) or_return
		append_uleb(bytes, 16 + u32(8 * layout.saved_count) + layout.frame_bytes) or_return
	}
	if has_return {
		total := len(offsets) - 1
		for index in 0 ..< layout.saved_count {
			unwind_advance(bytes, previous, offsets[total - layout.saved_count + index]) or_return
			register := layout.saved[layout.saved_count - index - 1]
			append(bytes, 0xc0 | unwind_register(register)) or_return
		}
		if layout.saved_count > 0 || layout.frame_bytes > 0 {
			unwind_advance(bytes, previous, offsets[total - 1]) or_return
			append(bytes, 0x0c, 7, 8) or_return // CFA=rsp+8 again.
		}
	}
	return nil
}
@(private)
emit_outermost_unwind :: proc(offset: u32, allocator: mem.Allocator) -> (bytes: []byte, err: runtime.Allocator_Error) {
	instructions := make([dynamic]byte, 0, 0, context.temp_allocator) or_return
	defer delete(instructions)
	previous: u32
	unwind_advance(&instructions, &previous, offset) or_return
	append(&instructions, 0x07, 16) or_return // DW_CFA_undefined rip: there is no caller.
	bytes = make([]byte, len(instructions), allocator) or_return
	copy(bytes, instructions[:])
	return
}

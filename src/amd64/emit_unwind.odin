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

@(private)
emit_frame_unwind :: proc(layout: Frame_Layout, offsets: []u32, has_return: bool, allocator: mem.Allocator) -> (bytes: []byte, err: runtime.Allocator_Error) {
	instructions := make([dynamic]byte, 0, 0, context.temp_allocator) or_return
	defer delete(instructions)
	previous: u32
	unwind_advance(&instructions, &previous, offsets[1]) or_return
	append(&instructions, 0x0e, 16, 0x86, 2) or_return // CFA=rsp+16; rbp at CFA-16.
	unwind_advance(&instructions, &previous, offsets[2]) or_return
	append(&instructions, 0x0d, 6) or_return // CFA=rbp+16, including dynamic stack allocation.
	for index in 0 ..< layout.saved_count {
		unwind_advance(&instructions, &previous, offsets[3 + index]) or_return
		append(&instructions, 0x80 | unwind_register(layout.saved[index]), byte(3 + index)) or_return
	}
	if has_return {
		pop_first := (len(offsets) - 1) - layout.saved_count - 2
		for index in 0 ..< layout.saved_count {
			unwind_advance(&instructions, &previous, offsets[pop_first + index + 1]) or_return
			register := layout.saved[layout.saved_count - index - 1]
			append(&instructions, 0xc0 | unwind_register(register)) or_return
		}
		unwind_advance(&instructions, &previous, offsets[(len(offsets) - 1) - 1]) or_return
		append(&instructions, 0x0c, 7, 8, 0xc6) or_return // After pop rbp, CFA=rsp+8.
	}
	bytes = make([]byte, len(instructions), allocator) or_return
	copy(bytes, instructions[:])
	return
}

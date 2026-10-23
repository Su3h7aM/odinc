package elf

import "base:runtime"

// CFI is borrowed until executable_build_unwind; the builder owns the resulting segment.
Unwind_Record :: struct {
	address, size: u64,
	instructions:  []byte,
}

executable_add_unwind :: proc(builder: ^Executable_Builder, address, size: u64, instructions: []byte) -> runtime.Allocator_Error {
	if builder.unwind == nil {
		builder.unwind = make([dynamic]Unwind_Record, 0, 0, builder.allocator) or_return
	}
	append(&builder.unwind, Unwind_Record{address, size, instructions}) or_return
	return nil
}

@(private = "file")
unwind_integer :: proc(bytes: ^[dynamic]byte, value: u64, width: int) -> runtime.Allocator_Error {
	for index in 0 ..< width {
		append(bytes, byte(value >> uint(8 * index))) or_return
	}
	return nil
}

@(private = "file")
unwind_relative :: proc(bytes: ^[dynamic]byte, target, base: u64) -> Error {
	delta := i64(target) - i64(base)
	if delta < -0x8000_0000 || delta > 0x7fff_ffff { return .Invalid_Segment }
	unwind_integer(bytes, u64(delta), 4) or_return
	return nil
}

// DWARF 6.4 and the AMD64 psABI unwind tables, without personality or LSDA.
executable_build_unwind :: proc(builder: ^Executable_Builder) -> Error {
	if len(builder.unwind) == 0 { return nil }
	for index in 1 ..< len(builder.unwind) {
		for cursor := index; cursor > 0 && builder.unwind[cursor].address < builder.unwind[cursor - 1].address; cursor -= 1 {
			builder.unwind[cursor], builder.unwind[cursor - 1] = builder.unwind[cursor - 1], builder.unwind[cursor]
		}
	}
	address: u64
	for segment in builder.segments {
		address = max(address, segment.vaddr + segment_memory_size(segment))
	}
	address = align_up(address, PAGE_SIZE)
	bytes := make([dynamic]byte, 0, 0, builder.allocator) or_return
	defer delete(bytes)
	fde_offsets := make([]u64, len(builder.unwind), builder.allocator) or_return
	defer delete(fde_offsets)
	// CIE v1, zR, code alignment 1, data alignment -8, return register rip, pcrel sdata4 pointers.
	append(&bytes, 0, 0, 0, 0, 0, 0, 0, 0, 1, 'z', 'R', 0, 1, 0x78, 16, 1, 0x1b) or_return
	append(&bytes, 0x0c, 7, 8, 0x90, 1) or_return
	registers := [?]byte{3, 6, 12, 13, 14, 15}
	for register in registers {
		append(&bytes, 0x08, register) or_return
	}
	for len(bytes) % 8 != 0 { append(&bytes, 0) or_return }
	blit(bytes[:], 0, u32le(len(bytes) - 4))
	for record, index in builder.unwind {
		start := len(bytes)
		fde_offsets[index] = u64(start)
		unwind_integer(&bytes, 0, 4) or_return
		unwind_integer(&bytes, u64(start + 4), 4) or_return
		unwind_relative(&bytes, record.address, address + u64(len(bytes))) or_return
		if record.size > 0x7fff_ffff { return .Invalid_Segment }
		unwind_integer(&bytes, record.size, 4) or_return
		append(&bytes, 0) or_return // Empty FDE augmentation.
		append(&bytes, ..record.instructions) or_return
		for len(bytes) % 8 != 0 { append(&bytes, 0) or_return }
		blit(bytes[:], start, u32le(len(bytes) - start - 4))
	}
	unwind_integer(&bytes, 0, 4) or_return
	frame_size := u64(len(bytes))
	for len(bytes) % 8 != 0 { append(&bytes, 0) or_return }
	header_offset := u64(len(bytes))
	// .eh_frame_hdr: pcrel sdata4 pointer, udata4 count, datarel sdata4 table.
	append(&bytes, 1, 0x1b, 3, 0x3b) or_return
	unwind_relative(&bytes, address, address + u64(len(bytes))) or_return
	unwind_integer(&bytes, u64(len(builder.unwind)), 4) or_return
	for record, index in builder.unwind {
		unwind_relative(&bytes, record.address, address + header_offset) or_return
		unwind_relative(&bytes, address + fde_offsets[index], address + header_offset) or_return
	}
	segment := executable_add_segment(builder, address, bytes[:], 0, {.PF_R}, 8) or_return
	builder.unwind_segment = segment
	builder.unwind_frame_size = frame_size
	builder.unwind_header_offset = header_offset
	return nil
}

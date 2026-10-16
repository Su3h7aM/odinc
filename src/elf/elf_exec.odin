package elf

import "core:mem"
import "core:slice"

/*
	Handle to a segment inside one `Executable_Builder`.  Zero never names
	a segment.
*/
Segment_Handle :: distinct u32

/*
	Bit positions of `p_flags`, the segment permissions.
*/
PF :: enum u8 {
	PF_X = 0, // 0x1: segment is executable
	PF_W = 1, // 0x2: segment is writable
	PF_R = 2, // 0x4: segment is readable
}

Program_Flags :: bit_set[PF; u32]

// Program header (`p_type`) values; the GNU ones are in the OS range.
PT_NULL       :: 0x00000000
PT_LOAD       :: 0x00000001
PT_GNU_STACK  :: 0x6474e551

/*
	The kernel maps at page granularity and requires
	`p_offset == p_vaddr (mod page size)`; smaller alignments can all too
	easily breach that rule, so the writer places segment content with it
	in mind whatever `alignment` the caller chose.
*/
PAGE_SIZE :: 4096

/*
	ELF64 program header (spec type Elf64_Phdr), 56 bytes.  `p_flags` is
	stored in its spec integer form; the spec's `p_type` values are
	package constants (`PT_NULL`, `PT_LOAD`, ...).
*/
Program_Header :: struct #packed {
	p_type:   u32le,
	p_flags:  u32le,
	p_offset: u64le,
	p_vaddr:  u64le,
	p_paddr:  u64le,
	p_filesz: u64le,
	p_memsz:  u64le,
	p_align:  u64le,
}

/*
	One segment recorded by the builder.  `data` holds the bytes that are
	written to the file; a `memsz` above their length is filled with zeros
	by the kernel at load (the `.bss` case).
*/
Executable_Segment :: struct {
	vaddr:     u64,
	memsz:     u64,
	flags:     Program_Flags,
	alignment: u64,
	data:      [dynamic]u8,
}

/*
	Accumulates segments of a static ET_EXEC x86-64 Linux executable until
	`executable_write` serializes it.  Entry address defaults to zero;
	see `executable_set_entry`.
*/
Executable_Builder :: struct {
	allocator: mem.Allocator,
	entry:     u64,
	segments:  [dynamic]Executable_Segment,
}

/*
	Returns a zero-content `Executable_Builder` that allocates with
	`allocator` (defaults to `context.allocator`).
*/
executable_builder_init :: proc(allocator := context.allocator) -> Executable_Builder {
	return Executable_Builder{allocator = allocator}
}

/*
	Frees everything the builder owns.  Afterwards the builder must not be
	used again.
*/
executable_builder_destroy :: proc(builder: ^Executable_Builder) {
	for seg in builder.segments {
		free_dynamic(seg.data)
	}
	free_dynamic(builder.segments)
}

/*
	Adds a segment at `vaddr` with permission `flags`.  The builder owns
	the copy of `data`; a `memsz` of `0` means "as long as `data`", and it
	may not fall below the data length.  `alignment` is the value written
	to `p_align`; zero means the page size.
*/
executable_add_segment :: proc(builder: ^Executable_Builder, vaddr: u64, data: []byte, memsz: u64, flags: Program_Flags, alignment: u64) -> (Segment_Handle, Error) {
	if memsz != 0 && memsz < u64(len(data)) {
		return 0, Error(.Invalid_Segment)
	}

	segment := Executable_Segment{vaddr = vaddr, memsz = memsz, flags = flags, alignment = alignment}
	if len(data) > 0 {
		segment.data = make([dynamic]u8, 0, builder.allocator)
		append(&segment.data, ..data)
	}

	if builder.segments == nil {
		builder.segments = make([dynamic]Executable_Segment, 0, builder.allocator)
	}
	append(&builder.segments, segment)
	return Segment_Handle(u32(len(builder.segments))), nil
}

/*
	Sets the entry address of the executable.
*/
executable_set_entry :: proc(builder: ^Executable_Builder, address: u64) {
	builder.entry = address
}

PROGRAM_HEADER_SIZE :: size_of(Program_Header) // 56

/*
	Returns the spec's integer form of a program flag set (the value that
	is stored in `p_flags`).
*/
program_flags_mask :: proc(flags: Program_Flags) -> u32 {
	return transmute(u32)(flags)
}

/*
	Serializes the builder into the bytes of a complete static ET_EXEC
	x86-64 Linux executable: the ELF header, PT_LOAD program headers for
	the segments in `vaddr` order with file offsets congruent to `vaddr`
	(mod alignment, at least one page), and a non-executable PT_GNU_STACK
	last.  No program interpreter, no dynamic linking, no section headers.

	`object` is exactly one allocation; the caller owns it and must
	`delete` it with the allocator given here.
*/
executable_write :: proc(builder: ^Executable_Builder, allocator := context.allocator) -> (object: []u8, err: Error) {
	segment_headers := make([dynamic]Program_Header, 0, allocator)
	defer free_dynamic(segment_headers)

	// Segments load in `vaddr` order; the sort is stable, so equal
	// addresses stay in insertion order.
	order := make([dynamic]int, len(builder.segments), allocator)
	defer free_dynamic(order)
	for index in 0..<len(order) {
		order[index] = index
	}
	for position := 1; position < len(order); position += 1 {
		swap_position := position
		for swap_position > 0 && builder.segments[order[swap_position]].vaddr < builder.segments[order[swap_position - 1]].vaddr {
			slice.swap(order[:], swap_position, swap_position - 1)
			swap_position -= 1
		}
	}

	// File offsets congruent to `vaddr` (mod alignment, at least one
	// page), packed after header and program header table.
	program_header_count := len(builder.segments) + 1
	cursor: u64 = FILE_HEADER_SIZE + PROGRAM_HEADER_SIZE * u64(program_header_count)
	for sorted_position in order {
		segment := builder.segments[sorted_position]

		alignment := segment.alignment
		if alignment == 0 || alignment < PAGE_SIZE {
			alignment = PAGE_SIZE
		}
		memsz := segment.memsz
		if memsz == 0 {
			memsz = u64(len(segment.data))
		}

		file_offset := align_congruent(cursor, segment.vaddr, alignment)
		append(&segment_headers, Program_Header{
			p_type   = u32le(PT_LOAD),
			p_flags  = u32le(program_flags_mask(segment.flags)),
			p_offset = u64le(file_offset),
			p_vaddr  = u64le(segment.vaddr),
			p_paddr  = u64le(segment.vaddr),
			p_filesz = u64le(u64(len(segment.data))),
			p_memsz  = u64le(memsz),
			p_align  = u64le(alignment),
		})
		cursor = file_offset + u64(len(segment.data))
	}

	// The last PT_GNU_STACK defines stack executability: this one makes
	// stacks non-executable.
	append(&segment_headers, Program_Header{
		p_type   = u32le(PT_GNU_STACK),
		p_flags  = u32le(program_flags_mask(Program_Flags{.PF_W, .PF_R})),
		p_align  = u64le(16),
	})

	total_size := cursor
	data, alloc_err := mem.alloc_bytes(int(total_size), allocator = allocator)
	if alloc_err != nil {
		return nil, Error(alloc_err)
	}
	object = data

	header_position := FILE_HEADER_SIZE
	for header in segment_headers {
		blit(object, int(header_position), header)
		header_position += PROGRAM_HEADER_SIZE
	}

	sorted_position := 0
	for segment_index in order {
		segment := builder.segments[segment_index]
		if len(segment.data) > 0 {
			file_offset := u64(segment_headers[sorted_position].p_offset)
			end_offset := file_offset + u64(len(segment.data))
			copy(object[int(file_offset):int(end_offset)], segment.data[:])
		}
		sorted_position += 1
	}

	blit(object, 0, File_Header{
		ident       = IDENTITY,
		e_type      = .ET_EXEC,
		e_machine   = .EM_X86_64,
		e_version   = u32le(EV_CURRENT),
		e_entry     = u64le(builder.entry),
		e_phoff     = u64le(FILE_HEADER_SIZE),
		e_ehsize    = u16le(FILE_HEADER_SIZE),
		e_phentsize = u16le(PROGRAM_HEADER_SIZE),
		e_phnum     = u16le(len(segment_headers)),
	})

	return object, nil
}

/*
	Rounds `pos` up to the smallest value congruent to `value` (mod
	`alignment`).
*/
align_congruent :: proc "contextless" (pos: u64, value: u64, alignment: u64) -> u64 {
	if alignment <= 1 {
		return pos
	}
	pos_remainder := pos % alignment
	value_remainder := value % alignment
	delta := value_remainder - pos_remainder
	if delta != 0 {
		delta += alignment
	}
	return pos + delta % alignment
}

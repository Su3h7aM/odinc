package elf

import "base:runtime"
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

Program_Flags :: bit_set[PF;u32]

// Program header (`p_type`) values; the GNU ones are in the OS range.
PT_NULL :: 0x00000000
PT_LOAD :: 0x00000001
PT_DYNAMIC :: 0x00000002
PT_INTERP :: 0x00000003
PT_PHDR :: 0x00000006
PT_GNU_STACK :: 0x6474e551
PT_TLS :: 0x00000007

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
	tls:       bool,
}

/*
	Accumulates segments of a static ET_EXEC x86-64 Linux executable until
	`executable_write` serializes it.  Entry address defaults to zero;
	see `executable_set_entry`.
*/
Executable_Builder :: struct {
	allocator:           mem.Allocator,
	entry:               u64,
	segments:            [dynamic]Executable_Segment,
	load_headers:        bool,
	loaded_header_vaddr: u64,
	interpreter_vaddr:   u64,
	interpreter_size:    u64,
	dynamic_vaddr:       u64,
	dynamic_size:        u64,
	symbols:             [dynamic]Executable_Symbol,
}

/*
	A `.symtab` entry for `executable_write`.  `name` is borrowed and must
	outlive the write.  `value` is an address, `size` the byte size or zero.
*/
Executable_Symbol :: struct {
	name:    string,
	binding: STB,
	kind:    STT,
	value:   u64,
	size:    u64,
}

/*
	Records a symbol.  Any symbol makes `executable_write` emit a section
	per loaded segment plus `.symtab`, `.strtab` and `.shstrtab`.
*/
executable_add_symbol :: proc(builder: ^Executable_Builder, name: string, binding: STB, kind: STT, value: u64, size: u64) -> runtime.Allocator_Error {
	if builder.symbols == nil {
		builder.symbols = make([dynamic]Executable_Symbol, 0, builder.allocator) or_return
	}
	append(&builder.symbols, Executable_Symbol{name = name, binding = binding, kind = kind, value = value, size = size}) or_return
	return nil
}

segment_memory_size :: proc "contextless" (segment: Executable_Segment) -> u64 {
	if segment.memsz == 0 {
		return u64(len(segment.data))
	}
	return segment.memsz
}

Symbol_Tail :: struct {
	bytes:                [dynamic]u8,
	section_table_offset: u64,
	section_count:        u16,
	shstrndx:             u16,
}

/*
	Lays out `.symtab`, `.strtab`, `.shstrtab` and the section table from
	file offset `start`.  Symbols outside every loaded segment are dropped.
*/
executable_build_symbol_tail :: proc(
	builder: ^Executable_Builder,
	file_offsets: []u64,
	start: u64,
	allocator: mem.Allocator,
) -> (
	tail: Symbol_Tail,
	err: runtime.Allocator_Error,
) {
	if len(builder.symbols) == 0 {
		return
	}

	shstrtab, strtab: String_Table
	string_table_init(&shstrtab, allocator)
	string_table_init(&strtab, allocator)
	defer string_table_destroy(&shstrtab, allocator)
	defer string_table_destroy(&strtab, allocator)

	section_headers := make([dynamic]Section_Header, 1, allocator) or_return
	defer free_dynamic(section_headers)
	section_of_segment := make([]u16, len(builder.segments), allocator) or_return
	defer delete(section_of_segment, allocator)
	bss_section_of_segment := make([]u16, len(builder.segments), allocator) or_return
	defer delete(bss_section_of_segment, allocator)
	for segment, index in builder.segments {
		if segment.tls {
			continue
		}
		flags := Section_Flags{.SHF_ALLOC}
		name := ".rodata"
		if .PF_W in segment.flags {
			flags += {.SHF_WRITE}
			name = ".data"
		}
		if .PF_X in segment.flags {
			flags += {.SHF_EXECINSTR}
			name = ".text"
		}
		filesz := u64(len(segment.data))
		memsz := segment_memory_size(segment)
		if filesz > 0 {
			section_of_segment[index] = u16(len(section_headers))
			name_offset := intern_string(&shstrtab, name) or_return
			append(
				&section_headers,
				Section_Header {
					sh_name = u32le(u32(name_offset)),
					sh_type = .SHT_PROGBITS,
					sh_flags = u64le(section_flags_mask(flags)),
					sh_addr = u64le(segment.vaddr),
					sh_offset = u64le(file_offsets[index]),
					sh_size = u64le(filesz),
					sh_addralign = u64le(max(segment.alignment, 1)),
				},
			) or_return
		}
		if memsz > filesz {
			bss_section_of_segment[index] = u16(len(section_headers))
			bss_name_offset := intern_string(&shstrtab, ".bss") or_return
			append(
				&section_headers,
				Section_Header {
					sh_name = u32le(u32(bss_name_offset)),
					sh_type = .SHT_NOBITS,
					sh_flags = u64le(section_flags_mask(flags)),
					sh_addr = u64le(segment.vaddr + filesz),
					sh_offset = u64le(file_offsets[index] + filesz),
					sh_size = u64le(memsz - filesz),
					sh_addralign = u64le(max(segment.alignment, 1)),
				},
			) or_return
		}
	}

	entries := make([dynamic]Symbol_Entry, 1, allocator) or_return
	defer free_dynamic(entries)
	first_global: u32
	for pass in 0 ..< 2 {
		for symbol in builder.symbols {
			if (symbol.binding == .STB_LOCAL) != (pass == 0) {
				continue
			}
			section: u16
			for segment, index in builder.segments {
				if segment.tls {
					continue
				}
				if symbol.value >= segment.vaddr {
					relative := symbol.value - segment.vaddr
					if relative < u64(len(segment.data)) {
						section = section_of_segment[index]
						break
					}
					if relative < segment_memory_size(segment) {
						section = bss_section_of_segment[index]
						break
					}
				}
			}
			if section == 0 {
				continue
			}
			name_offset := intern_string(&strtab, symbol.name) or_return
			append(
				&entries,
				Symbol_Entry {
					st_name = u32le(u32(name_offset)),
					st_info = u8(symbol.binding) << 4 | u8(symbol.kind),
					st_shndx = u16le(section),
					st_value = u64le(symbol.value),
					st_size = u64le(symbol.size),
				},
			) or_return
		}
		if pass == 0 {
			first_global = u32(len(entries))
		}
	}

	symtab_name := intern_string(&shstrtab, ".symtab") or_return
	strtab_name := intern_string(&shstrtab, ".strtab") or_return
	shstrtab_name := intern_string(&shstrtab, ".shstrtab") or_return

	symtab_offset := (start + 7) &~ 7
	symtab_size := u64(len(entries)) * SYMBOL_ENTRY_SIZE
	strtab_offset := symtab_offset + symtab_size
	shstrtab_offset := strtab_offset + u64(len(strtab.storage))
	section_table_offset := (shstrtab_offset + u64(len(shstrtab.storage)) + 7) &~ 7

	symtab_index := u32(len(section_headers))
	append(
		&section_headers,
		Section_Header {
			sh_name = u32le(u32(symtab_name)),
			sh_type = .SHT_SYMTAB,
			sh_offset = u64le(symtab_offset),
			sh_size = u64le(symtab_size),
			sh_link = u32le(symtab_index + 1),
			sh_info = u32le(first_global),
			sh_addralign = u64le(8),
			sh_entsize = u64le(SYMBOL_ENTRY_SIZE),
		},
		Section_Header {
			sh_name = u32le(u32(strtab_name)),
			sh_type = .SHT_STRTAB,
			sh_offset = u64le(strtab_offset),
			sh_size = u64le(len(strtab.storage)),
			sh_addralign = u64le(1),
		},
		Section_Header {
			sh_name = u32le(u32(shstrtab_name)),
			sh_type = .SHT_STRTAB,
			sh_offset = u64le(shstrtab_offset),
			sh_size = u64le(len(shstrtab.storage)),
			sh_addralign = u64le(1),
		},
	) or_return

	tail.bytes = make([dynamic]u8, section_table_offset + u64(len(section_headers)) * SECTION_HEADER_SIZE - start, allocator) or_return
	for entry, position in entries {
		blit(tail.bytes[:], int(symtab_offset - start) + position * SYMBOL_ENTRY_SIZE, entry)
	}
	copy(tail.bytes[strtab_offset - start:], strtab.storage[:])
	copy(tail.bytes[shstrtab_offset - start:], shstrtab.storage[:])
	for header, position in section_headers {
		blit(tail.bytes[:], int(section_table_offset - start) + position * SECTION_HEADER_SIZE, header)
	}
	tail.section_table_offset = section_table_offset
	tail.section_count = u16(len(section_headers))
	tail.shstrndx = u16(len(section_headers) - 1)
	return
}

intern_string :: proc(table: ^String_Table, name: string) -> (offset: u64, err: runtime.Allocator_Error) {
	if len(name) == 0 {
		return 0, nil
	}
	for entry in table.entries {
		if entry.name == name {
			return entry.offset, nil
		}
	}
	offset = u64(len(table.storage))
	append(&table.storage, name) or_return
	append(&table.storage, u8(0)) or_return
	append(&table.entries, String_Table_Entry{offset = offset, name = name}) or_return
	return offset, nil
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
	free_dynamic(builder.symbols)
}

/*
	Adds a segment at `vaddr` with permission `flags`.  The builder owns
	the copy of `data`; a `memsz` of `0` means "as long as `data`", and it
	may not fall below the data length.  `alignment` is the value written
	to `p_align`; zero means the page size.
*/
executable_add_segment :: proc(
	builder: ^Executable_Builder,
	vaddr: u64,
	data: []byte,
	memsz: u64,
	flags: Program_Flags,
	alignment: u64,
) -> (
	Segment_Handle,
	Error,
) {
	if memsz != 0 && memsz < u64(len(data)) {
		return 0, Error(.Invalid_Segment)
	}

	segment := Executable_Segment {
		vaddr     = vaddr,
		memsz     = memsz,
		flags     = flags,
		alignment = alignment,
	}
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


executable_add_tls_segment :: proc(
	builder: ^Executable_Builder,
	vaddr: u64,
	data: []byte,
	memsz: u64,
	flags: Program_Flags,
	alignment: u64,
) -> (
	Segment_Handle,
	Error,
) {
	h, err := executable_add_segment(builder, vaddr, data, memsz, flags, alignment)
	if err == nil {
		builder.segments[len(builder.segments) - 1].tls = true
	}
	return h, err
}

/*
	Sets the entry address of the executable.
*/
executable_set_entry :: proc(builder: ^Executable_Builder, address: u64) {
	builder.entry = address
}

// Maps the ELF and program headers at `vaddr` so a program interpreter can read them.
executable_load_headers :: proc(builder: ^Executable_Builder, vaddr: u64) {
	builder.load_headers = true
	builder.loaded_header_vaddr = vaddr
}

// `size` is the interpreter path in a loadable segment, including the NUL.
executable_set_interpreter :: proc(builder: ^Executable_Builder, vaddr, size: u64) {
	builder.interpreter_vaddr = vaddr
	builder.interpreter_size = size
}

// `size` is the dynamic array in a loadable segment.
executable_set_dynamic :: proc(builder: ^Executable_Builder, vaddr, size: u64) {
	builder.dynamic_vaddr = vaddr
	builder.dynamic_size = size
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
	for index in 0 ..< len(order) {
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
	if builder.load_headers {
		program_header_count += 2
	}
	if builder.interpreter_size > 0 {
		program_header_count += 1
	}
	if builder.dynamic_size > 0 {
		program_header_count += 1
	}
	cursor: u64 = FILE_HEADER_SIZE + PROGRAM_HEADER_SIZE * u64(program_header_count)
	file_offsets := make([]u64, len(builder.segments), allocator)
	defer delete(file_offsets, allocator)
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
		file_offsets[sorted_position] = file_offset
		append(
			&segment_headers,
			Program_Header {
				p_type = u32le(segment.tls ? PT_TLS : PT_LOAD),
				p_flags = u32le(program_flags_mask(segment.flags)),
				p_offset = u64le(file_offset),
				p_vaddr = u64le(segment.vaddr),
				p_paddr = u64le(segment.vaddr),
				p_filesz = u64le(u64(len(segment.data))),
				p_memsz = u64le(memsz),
				p_align = u64le(segment.tls ? max(segment.alignment, 1) : alignment),
			},
		)
		cursor = file_offset + u64(len(segment.data))
	}

	if builder.load_headers {
		header_span := PROGRAM_HEADER_SIZE * u64(program_header_count)
		append(
			&segment_headers,
			Program_Header {
				p_type = u32le(PT_PHDR),
				p_flags = u32le(program_flags_mask({.PF_R})),
				p_offset = u64le(FILE_HEADER_SIZE),
				p_vaddr = u64le(builder.loaded_header_vaddr + FILE_HEADER_SIZE),
				p_paddr = u64le(builder.loaded_header_vaddr + FILE_HEADER_SIZE),
				p_filesz = u64le(header_span),
				p_memsz = u64le(header_span),
				p_align = u64le(8),
			},
		)
		append(
			&segment_headers,
			Program_Header {
				p_type = u32le(PT_LOAD),
				p_flags = u32le(program_flags_mask({.PF_R})),
				p_offset = 0,
				p_vaddr = u64le(builder.loaded_header_vaddr),
				p_paddr = u64le(builder.loaded_header_vaddr),
				p_filesz = u64le(PAGE_SIZE),
				p_memsz = u64le(PAGE_SIZE),
				p_align = u64le(PAGE_SIZE),
			},
		)
	}
	if builder.interpreter_size > 0 {
		offset, found := load_file_offset(segment_headers[:], builder.interpreter_vaddr)
		if !found {
			return nil, .Invalid_Segment
		}
		append(
			&segment_headers,
			Program_Header {
				p_type = u32le(PT_INTERP),
				p_flags = u32le(program_flags_mask({.PF_R})),
				p_offset = u64le(offset),
				p_vaddr = u64le(builder.interpreter_vaddr),
				p_paddr = u64le(builder.interpreter_vaddr),
				p_filesz = u64le(builder.interpreter_size),
				p_memsz = u64le(builder.interpreter_size),
				p_align = 1,
			},
		)
	}
	if builder.dynamic_size > 0 {
		offset, found := load_file_offset(segment_headers[:], builder.dynamic_vaddr)
		if !found {
			return nil, .Invalid_Segment
		}
		append(
			&segment_headers,
			Program_Header {
				p_type = u32le(PT_DYNAMIC),
				p_flags = u32le(program_flags_mask({.PF_R, .PF_W})),
				p_offset = u64le(offset),
				p_vaddr = u64le(builder.dynamic_vaddr),
				p_paddr = u64le(builder.dynamic_vaddr),
				p_filesz = u64le(builder.dynamic_size),
				p_memsz = u64le(builder.dynamic_size),
				p_align = 8,
			},
		)
	}

	// The last PT_GNU_STACK defines stack executability: this one makes
	// stacks non-executable.
	append(
		&segment_headers,
		Program_Header{p_type = u32le(PT_GNU_STACK), p_flags = u32le(program_flags_mask(Program_Flags{.PF_W, .PF_R})), p_align = u64le(16)},
	)

	symbol_tail := executable_build_symbol_tail(builder, file_offsets, cursor, allocator) or_return
	defer free_dynamic(symbol_tail.bytes)
	total_size := cursor + u64(len(symbol_tail.bytes))
	data, alloc_err := mem.alloc_bytes(int(total_size), allocator = allocator)
	if alloc_err != nil {
		return nil, Error(alloc_err)
	}
	object = data
	copy(object[int(cursor):], symbol_tail.bytes[:])

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

	blit(
		object,
		0,
		File_Header {
			ident = IDENTITY,
			e_type = .ET_EXEC,
			e_machine = .EM_X86_64,
			e_version = u32le(EV_CURRENT),
			e_entry = u64le(builder.entry),
			e_phoff = u64le(FILE_HEADER_SIZE),
			e_ehsize = u16le(FILE_HEADER_SIZE),
			e_phentsize = u16le(PROGRAM_HEADER_SIZE),
			e_phnum = u16le(len(segment_headers)),
			e_shoff = u64le(symbol_tail.section_table_offset),
			e_shentsize = u16le(SECTION_HEADER_SIZE),
			e_shnum = u16le(symbol_tail.section_count),
			e_shstrndx = u16le(symbol_tail.shstrndx),
		},
	)

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

load_file_offset :: proc(headers: []Program_Header, vaddr: u64) -> (u64, bool) {
	for header in headers {
		if u32(header.p_type) != PT_LOAD {
			continue
		}
		start := u64(header.p_vaddr)
		if vaddr >= start && vaddr < start + u64(header.p_filesz) {
			return u64(header.p_offset) + (vaddr - start), true
		}
	}
	return 0, false
}

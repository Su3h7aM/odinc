package link

import "core:mem"
import "oc:elf"

PAGE_SIZE :: u64(0x1000)
// Image base. The first page holds the ELF and program headers and maps no section.
BASE :: u64(0x400000)
ATOM_UNDEFINED :: u32(0xffff_ffff)

Section_Kind :: enum u8 {
	Text,
	Rodata,
	Data,
	Bss,
	Tdata,
	Tbss,
}

Atom :: struct {
	section: Section_Kind,
	align:   u32,
	bytes:   []byte,
	size:    u64, // size > len(bytes) only for Bss and Tbss
	relocs:  []Relocation,
}

// `atom` is an index into `Input.atoms`, or `ATOM_UNDEFINED` for an extern.
Symbol :: struct {
	name:   string,
	atom:   u32,
	offset: u64,
}

// `offset` is the place within the atom, `symbol` an index into `Input.symbols`.
Relocation :: struct {
	offset: u32,
	symbol: u32,
	kind:   elf.R_X86_64,
	addend: i64,
}

Input :: struct {
	atoms:   []Atom,
	symbols: []Symbol,
	entry:   string,
}

Duplicate_Symbol :: struct {
	name: string,
}
Undefined_Symbol :: struct {
	name: string,
}
Missing_Entry :: struct {
	name: string,
}
Relocation_Out_Of_Atom :: struct {
	symbol: u32,
	atom:   u32,
	offset: u32,
}
Unsupported_Relocation :: struct {
	kind: elf.R_X86_64,
}
Relocation_Overflow :: struct {
	symbol: u32,
	atom:   u32,
	offset: u32,
	value:  i64,
}

Link_Error :: union {
	Duplicate_Symbol,
	Undefined_Symbol,
	Missing_Entry,
	Relocation_Out_Of_Atom,
	Unsupported_Relocation,
	Relocation_Overflow,
	elf.Error,
	mem.Allocator_Error,
}

Layout :: struct {
	text_start:   u64,
	text_end:     u64,
	rodata_start: u64,
	rodata_end:   u64,
	rw_start:     u64,
	tdata_end:    u64,
	data_end:     u64,
	bss_end:      u64,
	tls_size:     u64,
	tls_align:    u64,
}

/*
	Lays out, relocates and writes a static ET_EXEC image. The result is
	owned by the caller and freed with `allocator`. Errors: the
	`Link_Error` variants, `Relocation_Overflow` for a 32-bit field that
	does not fit `i32`.
*/
link :: proc(input: Input, allocator: mem.Allocator) -> (image: []byte, err: Link_Error) {
	atom_addresses := make([]u64, len(input.atoms), allocator) or_return
	defer delete(atom_addresses, allocator)
	symbol_addresses := make([]u64, len(input.symbols), allocator) or_return
	defer delete(symbol_addresses, allocator)

	layout := place_atoms(input.atoms, atom_addresses)

	defined := make(map[string]u32, allocator = allocator)
	defer delete(defined)
	for symbol, index in input.symbols {
		if symbol.atom == ATOM_UNDEFINED { continue }
		if symbol.name in defined { return nil, Duplicate_Symbol{name = symbol.name} }
		defined[symbol.name] = u32(index)
		symbol_addresses[index] = atom_addresses[symbol.atom] + symbol.offset
	}
	entry_index, has_entry := defined[input.entry]
	if !has_entry { return nil, Missing_Entry{name = input.entry} }

	// Atoms with file bytes: text, rodata, tdata and data. Bss and Tbss take address space only.
	load_bytes := make([]byte, layout.data_end - layout.text_start, allocator) or_return
	defer delete(load_bytes, allocator)
	for atom, index in input.atoms {
		if len(atom.bytes) == 0 { continue }
		start := atom_addresses[index] - layout.text_start
		copy(load_bytes[start:], atom.bytes)
	}

	apply_relocations(input, atom_addresses, symbol_addresses, load_bytes, layout.text_start) or_return

	builder := elf.executable_builder_init(allocator)
	defer elf.executable_builder_destroy(&builder)

	text_file_end := layout.text_end - layout.text_start
	if text_file_end > 0 {
		add_load_segment(&builder, layout.text_start, load_bytes[:text_file_end], 0, {.PF_R, .PF_X}) or_return
	}
	if layout.rodata_end > layout.rodata_start {
		rodata := load_bytes[layout.rodata_start - layout.text_start:layout.rodata_end - layout.text_start]
		add_load_segment(&builder, layout.rodata_start, rodata, 0, {.PF_R}) or_return
	}
	if layout.bss_end > layout.rw_start {
		rw := load_bytes[layout.rw_start - layout.text_start:layout.data_end - layout.text_start]
		add_load_segment(&builder, layout.rw_start, rw, layout.bss_end - layout.rw_start, {.PF_R, .PF_W}) or_return
	}
	if layout.tls_size > 0 {
		template := load_bytes[layout.rw_start - layout.text_start:layout.tdata_end - layout.text_start]
		_, tls_err := elf.executable_add_tls_segment(&builder, layout.rw_start, template, layout.tls_size, {.PF_R}, layout.tls_align)
		if tls_err != nil { return nil, tls_err }
	}
	elf.executable_set_entry(&builder, symbol_addresses[entry_index])

	object, write_err := elf.executable_write(&builder, allocator)
	if write_err != nil { return nil, write_err }
	return object, nil
}

place_atoms :: proc(atoms: []Atom, addresses: []u64) -> (layout: Layout) {
	layout.text_start = BASE + PAGE_SIZE
	layout.text_end = place_section(atoms, addresses, .Text, layout.text_start)
	layout.rodata_start = align_up(layout.text_end, PAGE_SIZE)
	layout.rodata_end = place_section(atoms, addresses, .Rodata, layout.rodata_start)
	layout.rw_start = align_up(layout.rodata_end, PAGE_SIZE)
	layout.tdata_end = place_section(atoms, addresses, .Tdata, layout.rw_start)
	layout.data_end = place_section(atoms, addresses, .Data, layout.tdata_end)
	layout.bss_end = place_section(atoms, addresses, .Bss, layout.data_end)
	// Tbss addresses are offsets inside the TLS block, which starts at `rw_start`.
	layout.tls_size = place_section(atoms, addresses, .Tbss, layout.tdata_end - layout.rw_start)
	layout.tls_align = 1
	for atom in atoms {
		if atom.section == .Tdata || atom.section == .Tbss {
			layout.tls_align = max(layout.tls_align, u64(atom.align))
		}
	}
	return
}

place_section :: proc(atoms: []Atom, addresses: []u64, section: Section_Kind, cursor: u64) -> u64 {
	position := cursor
	for atom, index in atoms {
		if atom.section != section { continue }
		position = align_up(position, u64(max(atom.align, 1)))
		addresses[index] = position
		position += max(atom.size, u64(len(atom.bytes)))
	}
	return position
}

align_up :: proc(value, alignment: u64) -> u64 {
	return (value + alignment - 1) / alignment * alignment
}

add_load_segment :: proc(builder: ^elf.Executable_Builder, vaddr: u64, data: []byte, memsz: u64, flags: elf.Program_Flags) -> Link_Error {
	_, err := elf.executable_add_segment(builder, vaddr, data, memsz, flags, PAGE_SIZE)
	if err != nil { return err }
	return nil
}

apply_relocations :: proc(input: Input, atom_addresses, symbol_addresses: []u64, load_bytes: []byte, load_base: u64) -> Link_Error {
	for atom, atom_index in input.atoms {
		for reloc in atom.relocs {
			field_size: int
			#partial switch reloc.kind {
			case .R_X86_64_64:
				field_size = 8
			case .R_X86_64_PC32, .R_X86_64_PLT32, .R_X86_64_32S:
				field_size = 4
			case:
				return Unsupported_Relocation{kind = reloc.kind}
			}
			if u64(reloc.offset) + u64(field_size) > u64(len(atom.bytes)) {
				return Relocation_Out_Of_Atom{symbol = reloc.symbol, atom = u32(atom_index), offset = reloc.offset}
			}
			if input.symbols[reloc.symbol].atom == ATOM_UNDEFINED {
				return Undefined_Symbol{name = input.symbols[reloc.symbol].name}
			}

			target := i64(symbol_addresses[reloc.symbol]) + reloc.addend
			place := i64(atom_addresses[atom_index]) + i64(reloc.offset)
			value := target
			if reloc.kind == .R_X86_64_PC32 || reloc.kind == .R_X86_64_PLT32 {
				value = target - place
			}
			if field_size == 4 && i64(i32(value)) != value {
				return Relocation_Overflow{symbol = reloc.symbol, atom = u32(atom_index), offset = reloc.offset, value = value}
			}

			field_start := place - i64(load_base)
			store_little_endian(load_bytes[field_start:field_start + i64(field_size)], u64(value))
		}
	}
	return nil
}

store_little_endian :: proc(field: []byte, value: u64) {
	for index in 0 ..< len(field) {
		field[index] = u8(value >> (8 * uint(index)))
	}
}

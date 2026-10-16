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

// `atom` is an index into the `atoms` of the same `Input`, or `ATOM_UNDEFINED` for an extern.
Symbol :: struct {
	name:   string,
	atom:   u32,
	offset: u64,
}

// `offset` is the place within the atom, `symbol` an index into the `symbols` of the same `Input`.
Relocation :: struct {
	offset: u32,
	symbol: u32,
	kind:   elf.R_X86_64,
	addend: i64,
}

Input :: struct {
	atoms:   []Atom,
	symbols: []Symbol,
}

// A symbol after name binding: a defined symbol of any input, or the extern it names.
Resolved_Symbol :: struct {
	address: u64,
	section: Section_Kind,
	defined: bool,
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
	input:  u32,
	symbol: u32,
	atom:   u32,
	offset: u32,
}
Unsupported_Relocation :: struct {
	kind: elf.R_X86_64,
}
Relocation_Overflow :: struct {
	input:  u32,
	symbol: u32,
	atom:   u32,
	offset: u32,
	value:  i64,
}
Relocation_Not_Thread_Local :: struct {
	input:  u32,
	symbol: u32,
	atom:   u32,
	offset: u32,
}

Link_Error :: union {
	Duplicate_Symbol,
	Undefined_Symbol,
	Missing_Entry,
	Relocation_Out_Of_Atom,
	Unsupported_Relocation,
	Relocation_Overflow,
	Relocation_Not_Thread_Local,
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
	Lays out, relocates and writes a static ET_EXEC image from one or more
	inputs. Defined symbols bind by name across all inputs; `entry` names
	the start symbol. The result is owned by the caller and freed with
	`allocator`.
*/
link :: proc(inputs: []Input, entry: string, allocator: mem.Allocator) -> (image: []byte, err: Link_Error) {
	atom_addresses := make([][]u64, len(inputs), allocator) or_return
	defer {
		for addresses in atom_addresses { delete(addresses, allocator) }
		delete(atom_addresses, allocator)
	}
	for input, index in inputs {
		atom_addresses[index] = make([]u64, len(input.atoms), allocator) or_return
	}

	layout := place_atoms(inputs, atom_addresses)

	defined := make(map[string]Resolved_Symbol, allocator = allocator)
	defer delete(defined)
	for input, input_index in inputs {
		for symbol in input.symbols {
			if symbol.atom == ATOM_UNDEFINED { continue }
			if symbol.name in defined { return nil, Duplicate_Symbol{name = symbol.name} }
			atom := input.atoms[symbol.atom]
			defined[symbol.name] = Resolved_Symbol {
				address = atom_addresses[input_index][symbol.atom] + symbol.offset,
				section = atom.section,
				defined = true,
			}
		}
	}
	entry_symbol, has_entry := defined[entry]
	if !has_entry { return nil, Missing_Entry{name = entry} }

	symbols := make([][]Resolved_Symbol, len(inputs), allocator) or_return
	defer {
		for resolved in symbols { delete(resolved, allocator) }
		delete(symbols, allocator)
	}
	for input, index in inputs {
		symbols[index] = make([]Resolved_Symbol, len(input.symbols), allocator) or_return
		for symbol, symbol_index in input.symbols {
			symbols[index][symbol_index] = defined[symbol.name] or_else Resolved_Symbol{}
		}
	}

	// Atoms with file bytes: text, rodata, tdata and data. Bss and Tbss take address space only.
	load_bytes := make([]byte, layout.data_end - layout.text_start, allocator) or_return
	defer delete(load_bytes, allocator)
	for input, input_index in inputs {
		for atom, atom_index in input.atoms {
			if len(atom.bytes) == 0 { continue }
			start := atom_addresses[input_index][atom_index] - layout.text_start
			copy(load_bytes[start:], atom.bytes)
		}
	}

	apply_relocations(inputs, atom_addresses, symbols, load_bytes, layout) or_return

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
	elf.executable_set_entry(&builder, entry_symbol.address)

	object, write_err := elf.executable_write(&builder, allocator)
	if write_err != nil { return nil, write_err }
	return object, nil
}

// Tbss addresses are virtual: the TLS block offset of an address is `address - rw_start`.
place_atoms :: proc(inputs: []Input, addresses: [][]u64) -> (layout: Layout) {
	layout.text_start = BASE + PAGE_SIZE
	layout.text_end = place_section(inputs, addresses, .Text, layout.text_start)
	layout.rodata_start = align_up(layout.text_end, PAGE_SIZE)
	layout.rodata_end = place_section(inputs, addresses, .Rodata, layout.rodata_start)
	layout.rw_start = align_up(layout.rodata_end, PAGE_SIZE)
	layout.tdata_end = place_section(inputs, addresses, .Tdata, layout.rw_start)
	layout.data_end = place_section(inputs, addresses, .Data, layout.tdata_end)
	layout.bss_end = place_section(inputs, addresses, .Bss, layout.data_end)
	layout.tls_size = place_section(inputs, addresses, .Tbss, layout.tdata_end) - layout.rw_start
	layout.tls_align = 1
	for input in inputs {
		for atom in input.atoms {
			if atom.section == .Tdata || atom.section == .Tbss {
				layout.tls_align = max(layout.tls_align, u64(atom.align))
			}
		}
	}
	return
}

place_section :: proc(inputs: []Input, addresses: [][]u64, section: Section_Kind, cursor: u64) -> u64 {
	position := cursor
	for input, input_index in inputs {
		for atom, atom_index in input.atoms {
			if atom.section != section { continue }
			position = align_up(position, u64(max(atom.align, 1)))
			addresses[input_index][atom_index] = position
			position += max(atom.size, u64(len(atom.bytes)))
		}
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

apply_relocations :: proc(inputs: []Input, atom_addresses: [][]u64, symbols: [][]Resolved_Symbol, load_bytes: []byte, layout: Layout) -> Link_Error {
	thread_pointer := align_up(layout.rw_start + layout.tls_size, layout.tls_align)
	for input, input_index in inputs {
		for atom, atom_index in input.atoms {
			for reloc in atom.relocs {
				field_size: int
				#partial switch reloc.kind {
				case .R_X86_64_64:
					field_size = 8
				case .R_X86_64_PC32, .R_X86_64_PLT32, .R_X86_64_32, .R_X86_64_32S, .R_X86_64_TPOFF32:
					field_size = 4
				case:
					return Unsupported_Relocation{kind = reloc.kind}
				}
				if u64(reloc.offset) + u64(field_size) > u64(len(atom.bytes)) {
					return Relocation_Out_Of_Atom{input = u32(input_index), symbol = reloc.symbol, atom = u32(atom_index), offset = reloc.offset}
				}
				target_symbol := symbols[input_index][reloc.symbol]
				if !target_symbol.defined {
					return Undefined_Symbol{name = input.symbols[reloc.symbol].name}
				}

				target := i64(target_symbol.address) + reloc.addend
				place := i64(atom_addresses[input_index][atom_index]) + i64(reloc.offset)
				value := target
				#partial switch reloc.kind {
				case .R_X86_64_PC32, .R_X86_64_PLT32:
					value = target - place
				case .R_X86_64_TPOFF32:
					if target_symbol.section != .Tdata && target_symbol.section != .Tbss {
						return Relocation_Not_Thread_Local{input = u32(input_index), symbol = reloc.symbol, atom = u32(atom_index), offset = reloc.offset}
					}
					value = target - i64(thread_pointer)
				}
				if !fits_field(reloc.kind, value) {
					return Relocation_Overflow{input = u32(input_index), symbol = reloc.symbol, atom = u32(atom_index), offset = reloc.offset, value = value}
				}

				field_start := place - i64(layout.text_start)
				store_little_endian(load_bytes[field_start:field_start + i64(field_size)], u64(value))
			}
		}
	}
	return nil
}

fits_field :: proc(kind: elf.R_X86_64, value: i64) -> bool {
	#partial switch kind {
	case .R_X86_64_64:
		return true
	case .R_X86_64_32:
		return value >= 0 && value <= i64(max(u32))
	case:
		return i64(i32(value)) == value
	}
}

store_little_endian :: proc(field: []byte, value: u64) {
	for index in 0 ..< len(field) {
		field[index] = u8(value >> (8 * uint(index)))
	}
}

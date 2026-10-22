package link

import "core:mem"
import "core:strings"
import "oc:elf"

PAGE_SIZE :: u64(0x1000)
// The thread control block is the 8-byte word at the thread pointer; its atom holds a self pointer.
TCB_ALIGN :: u64(8)
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
	Tcb,
}

Atom :: struct {
	section:   Section_Kind,
	align:     u32,
	bytes:     []byte,
	size:      u64, // size > len(bytes) only for Bss and Tbss
	relocs:    []Relocation,
	discarded: bool,
}

Binding :: enum u8 {
	Global,
	Weak,
	Local,
}

// `atom` is an index into the `atoms` of the same `Input`, or `ATOM_UNDEFINED` for an extern.
Symbol :: struct {
	name:      string,
	atom:      u32,
	offset:    u64,
	binding:   Binding,
	absolute:  bool,
	tentative: bool,
}

// `offset` is the place within the atom, `symbol` an index into the `symbols` of the same `Input`.
Relocation :: struct {
	offset: u32,
	symbol: u32,
	kind:   elf.R_X86_64,
	addend: i64,
}

Comdat :: struct {
	signature: string,
	atoms:     []u32,
}

Input :: struct {
	atoms:   []Atom,
	symbols: []Symbol,
	comdats: []Comdat,
}

// A symbol after name binding: a defined symbol of any input, or the extern it names.
Resolved_Symbol :: struct {
	address:    u64,
	section:    Section_Kind,
	defined:    bool,
	is_dynamic: bool,
}

Duplicate_Symbol :: struct {
	name: string,
}
Undefined_Symbol :: struct {
	name: string,
}
// Every unresolved relocation target, each name once, in input order. The slice and each name are allocated with the
// link allocator; free them with undefined_symbols_destroy.
Undefined_Symbols :: struct {
	names: []string,
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
Malformed_File :: struct {
	detail: string,
}

Link_Error :: union {
	Duplicate_Symbol,
	Undefined_Symbol,
	Undefined_Symbols,
	Missing_Entry,
	Relocation_Out_Of_Atom,
	Unsupported_Relocation,
	Relocation_Overflow,
	Relocation_Not_Thread_Local,
	Malformed_File,
	elf.Error,
	mem.Allocator_Error,
}

Layout :: struct {
	text_start:     u64,
	text_end:       u64,
	rodata_start:   u64,
	rodata_end:     u64,
	rw_start:       u64,
	tdata_end:      u64,
	data_end:       u64,
	bss_end:        u64,
	tls_size:       u64,
	tls_align:      u64,
	tbss_end:       u64,
	thread_pointer: u64,
	text_tail:      u64,
	rodata_tail:    u64,
	data_tail:      u64,
}

/*
	Lays out, relocates and writes a static ET_EXEC image from one or more
	inputs. Defined symbols bind by name across all inputs; `entry` names
	the start symbol. The result is owned by the caller and freed with
	`allocator`.
*/
link :: proc(inputs: []Input, entry: string, allocator: mem.Allocator) -> (image: []byte, err: Link_Error) {
	return link_with(inputs, nil, nil, entry, allocator)
}

/*
	Links `inputs`. `needed` and `provided` describe shared libraries: a
	global symbol missing from `inputs` and present in `provided` is
	resolved by the dynamic linker.
*/
link_with :: proc(inputs: []Input, needed: []string, provided: map[string]bool, entry: string, allocator: mem.Allocator) -> (image: []byte, err: Link_Error) {
	atom_addresses := make([][]u64, len(inputs), allocator) or_return
	defer {
		for addresses in atom_addresses { delete(addresses, allocator) }
		delete(atom_addresses, allocator)
	}
	for input, index in inputs {
		atom_addresses[index] = make([]u64, len(input.atoms), allocator) or_return
	}

	discard_comdats(inputs)
	choices := make(map[string]Symbol_Choice, allocator = allocator)
	defer delete(choices)
	choose_symbols(inputs, &choices) or_return

	fixups := fixups_init(allocator)
	defer fixups_destroy(&fixups)
	plan_fixups(inputs, choices, provided, &fixups)
	layout := place_atoms(inputs, atom_addresses, text_tail_size(fixups), rodata_tail_size(fixups, needed), data_tail_size(fixups, needed))
	assign_fixup_addresses(&fixups, layout, needed)

	defined := make(map[string]Resolved_Symbol, allocator = allocator)
	defer delete(defined)
	for name, choice in choices {
		defined[name] = resolve_choice(inputs, atom_addresses, choice)
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
			symbols[index][symbol_index] = resolve_use(inputs, atom_addresses, defined, provided, index, symbol)
		}
	}

	// Atoms with file bytes: text, rodata, tdata and data. Bss and Tbss take address space only.
	load_bytes := make([]byte, layout.data_end - layout.text_start, allocator) or_return
	defer delete(load_bytes, allocator)
	for input, input_index in inputs {
		for atom, atom_index in input.atoms {
			if atom.discarded || len(atom.bytes) == 0 { continue }
			start := atom_addresses[input_index][atom_index] - layout.text_start
			copy(load_bytes[start:], atom.bytes)
		}
	}

	undefined, collect_err := collect_undefined_symbols(inputs, symbols, allocator)
	if collect_err != nil { return nil, collect_err }
	if len(undefined.names) > 0 { return nil, undefined }
	undefined_symbols_destroy(undefined, allocator)
	apply_relocations(inputs, atom_addresses, symbols, load_bytes, layout, &fixups) or_return
	fill_dynamic(atom_addresses, symbols, load_bytes, layout, fixups, needed)

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
	elf.executable_load_headers(&builder, BASE)
	configure_dynamic_program(&builder, layout, fixups, needed)
	add_symbol_table(&builder, inputs, atom_addresses, choices) or_return

	object, write_err := elf.executable_write(&builder, allocator)
	if write_err != nil { return nil, write_err }
	return object, nil
}

// Tbss addresses are virtual: the TLS block offset of an address is `address - rw_start`.
place_atoms :: proc(inputs: []Input, addresses: [][]u64, text_tail: u64 = 0, rodata_tail: u64 = 0, data_tail: u64 = 0) -> (layout: Layout) {
	layout.text_start = BASE + PAGE_SIZE
	layout.text_end = place_section(inputs, addresses, .Text, layout.text_start)
	if text_tail > 0 {
		layout.text_tail = align_up(layout.text_end, 16)
		layout.text_end = layout.text_tail + text_tail
	} else {
		layout.text_tail = layout.text_end
	}
	layout.rodata_start = align_up(layout.text_end, PAGE_SIZE)
	layout.rodata_end = place_section(inputs, addresses, .Rodata, layout.rodata_start)
	if rodata_tail > 0 {
		layout.rodata_tail = align_up(layout.rodata_end, 8)
		layout.rodata_end = layout.rodata_tail + rodata_tail
	} else {
		layout.rodata_tail = layout.rodata_end
	}
	layout.rw_start = align_up(layout.rodata_end, PAGE_SIZE)
	layout.tdata_end = place_section(inputs, addresses, .Tdata, layout.rw_start)
	layout.tbss_end = place_section(inputs, addresses, .Tbss, layout.tdata_end)
	layout.tls_size = layout.tbss_end - layout.rw_start
	layout.tls_align = 1
	for input in inputs {
		for atom in input.atoms {
			if atom.section == .Tdata || atom.section == .Tbss {
				layout.tls_align = max(layout.tls_align, u64(atom.align))
			}
		}
	}
	layout.thread_pointer = layout.rw_start + align_up(layout.tls_size, max(layout.tls_align, TCB_ALIGN))
	tcb_end := place_section(inputs, addresses, .Tcb, layout.thread_pointer)
	data_placed := place_section(inputs, addresses, .Data, tcb_end)
	layout.data_end = data_placed
	if data_tail > 0 {
		layout.data_tail = align_up(data_placed, 8)
		layout.data_end = layout.data_tail + data_tail
	} else {
		layout.data_tail = data_placed
	}
	layout.bss_end = place_section(inputs, addresses, .Bss, layout.data_end)
	return
}

place_section :: proc(inputs: []Input, addresses: [][]u64, section: Section_Kind, cursor: u64) -> u64 {
	position := cursor
	for input, input_index in inputs {
		for atom, atom_index in input.atoms {
			if atom.discarded || atom.section != section { continue }
			position = align_up(position, u64(max(atom.align, 1)))
			addresses[input_index][atom_index] = position
			position += max(atom.size, u64(len(atom.bytes)))
		}
	}
	return position
}

Symbol_Choice :: struct {
	input:  u32,
	symbol: u32,
}

discard_comdats :: proc(inputs: []Input) {
	seen := make(map[string]bool)
	defer delete(seen)
	for &input in inputs {
		for comdat in input.comdats {
			if comdat.signature in seen {
				for atom_index in comdat.atoms {
					input.atoms[atom_index].discarded = true
				}
				continue
			}
			seen[comdat.signature] = true
		}
	}
}

choose_symbols :: proc(inputs: []Input, choices: ^map[string]Symbol_Choice) -> Link_Error {
	for &input, input_index in inputs {
		for &symbol, symbol_index in input.symbols {
			if symbol.binding == .Local || len(symbol.name) == 0 || !symbol_defines(input, symbol) {
				continue
			}
			choice := Symbol_Choice {
				input  = u32(input_index),
				symbol = u32(symbol_index),
			}
			if previous, found := choices[symbol.name]; found {
				keep, duplicate := prefer_symbol(inputs, previous, choice)
				if duplicate {
					return Duplicate_Symbol{name = symbol.name}
				}
				if keep != previous {
					drop_tentative(inputs, previous)
					choices[symbol.name] = keep
				} else {
					drop_tentative(inputs, choice)
				}
			} else {
				choices[symbol.name] = choice
			}
		}
	}
	return nil
}

symbol_defines :: proc(input: Input, symbol: Symbol) -> bool {
	if symbol.absolute {
		return true
	}
	if symbol.atom == ATOM_UNDEFINED || int(symbol.atom) >= len(input.atoms) {
		return false
	}
	return !input.atoms[symbol.atom].discarded
}

symbol_strength :: proc(symbol: Symbol) -> int {
	if symbol.tentative {
		return 1
	}
	if symbol.binding == .Weak {
		return 2
	}
	return 3
}

prefer_symbol :: proc(inputs: []Input, previous, candidate: Symbol_Choice) -> (keep: Symbol_Choice, duplicate: bool) {
	old := inputs[previous.input].symbols[previous.symbol]
	new := inputs[candidate.input].symbols[candidate.symbol]
	old_strength := symbol_strength(old)
	new_strength := symbol_strength(new)
	if old_strength == 3 && new_strength == 3 {
		return previous, true
	}
	if new_strength > old_strength {
		return candidate, false
	}
	if new_strength == old_strength && new.tentative {
		new_size := inputs[candidate.input].atoms[new.atom].size
		old_size := inputs[previous.input].atoms[old.atom].size
		if new_size > old_size {
			return candidate, false
		}
	}
	return previous, false
}

drop_tentative :: proc(inputs: []Input, choice: Symbol_Choice) {
	symbol := inputs[choice.input].symbols[choice.symbol]
	if symbol.tentative && symbol.atom != ATOM_UNDEFINED {
		inputs[choice.input].atoms[symbol.atom].discarded = true
	}
}

resolve_choice :: proc(inputs: []Input, addresses: [][]u64, choice: Symbol_Choice) -> Resolved_Symbol {
	symbol := inputs[choice.input].symbols[choice.symbol]
	if symbol.absolute {
		return Resolved_Symbol{address = symbol.offset, defined = true}
	}
	atom := inputs[choice.input].atoms[symbol.atom]
	return Resolved_Symbol{address = addresses[choice.input][symbol.atom] + symbol.offset, section = atom.section, defined = true}
}

resolve_use :: proc(
	inputs: []Input,
	addresses: [][]u64,
	defined: map[string]Resolved_Symbol,
	provided: map[string]bool,
	input_index: int,
	symbol: Symbol,
) -> Resolved_Symbol {
	if symbol.binding == .Local {
		if symbol.absolute {
			return Resolved_Symbol{address = symbol.offset, defined = true}
		}
		if symbol.atom == ATOM_UNDEFINED || int(symbol.atom) >= len(inputs[input_index].atoms) {
			return {}
		}
		atom := inputs[input_index].atoms[symbol.atom]
		if atom.discarded {
			return {}
		}
		return Resolved_Symbol{address = addresses[input_index][symbol.atom] + symbol.offset, section = atom.section, defined = true}
	}
	if resolved, found := defined[symbol.name]; found {
		return resolved
	}
	if symbol.name in provided {
		return Resolved_Symbol{defined = true, is_dynamic = true}
	}
	if symbol.binding == .Weak {
		return Resolved_Symbol{defined = true}
	}
	return {}
}

align_up :: proc(value, alignment: u64) -> u64 {
	return (value + alignment - 1) / alignment * alignment
}

add_load_segment :: proc(builder: ^elf.Executable_Builder, vaddr: u64, data: []byte, memsz: u64, flags: elf.Program_Flags) -> Link_Error {
	_, err := elf.executable_add_segment(builder, vaddr, data, memsz, flags, PAGE_SIZE)
	if err != nil { return err }
	return nil
}

undefined_symbols_destroy :: proc(undefined: Undefined_Symbols, allocator: mem.Allocator) {
	for name in undefined.names {
		delete(name, allocator)
	}
	delete(undefined.names, allocator)
}

// Collects every relocation target that resolved to nothing, so one link reports all missing symbols.
collect_undefined_symbols :: proc(
	inputs: []Input,
	symbols: [][]Resolved_Symbol,
	allocator: mem.Allocator,
) -> (
	undefined: Undefined_Symbols,
	err: mem.Allocator_Error,
) {
	names := make([dynamic]string, allocator) or_return
	seen := make(map[string]bool, allocator = allocator)
	defer delete(seen)
	for input, input_index in inputs {
		for atom in input.atoms {
			if atom.discarded { continue }
			for reloc in atom.relocs {
				if symbols[input_index][reloc.symbol].defined { continue }
				name := input.symbols[reloc.symbol].name
				if name in seen { continue }
				seen[name] = true
				cloned, clone_err := strings.clone(name, allocator)
				if clone_err != nil {
					undefined_symbols_destroy({names = names[:]}, allocator)
					return {}, clone_err
				}
				if _, append_err := append(&names, cloned); append_err != nil {
					delete(cloned, allocator)
					undefined_symbols_destroy({names = names[:]}, allocator)
					return {}, append_err
				}
			}
		}
	}
	return Undefined_Symbols{names = names[:]}, nil
}

apply_relocations :: proc(
	inputs: []Input,
	atom_addresses: [][]u64,
	symbols: [][]Resolved_Symbol,
	load_bytes: []byte,
	layout: Layout,
	fixups: ^Fixups,
) -> Link_Error {
	for input, input_index in inputs {
		for atom, atom_index in input.atoms {
			if atom.discarded {
				continue
			}
			apply_atom_relocations(
				input,
				input_index,
				atom_index,
				atom,
				symbols[input_index],
				atom_addresses[input_index][atom_index],
				load_bytes,
				layout,
				fixups,
			) or_return
		}
	}
	return nil
}

apply_atom_relocations :: proc(
	input: Input,
	input_index: int,
	atom_index: int,
	atom: Atom,
	symbols: []Resolved_Symbol,
	atom_address: u64,
	load_bytes: []byte,
	layout: Layout,
	fixups: ^Fixups,
) -> Link_Error {
	for reloc in atom.relocs {
		field_size: int
		#partial switch reloc.kind {
		case .R_X86_64_64:
			field_size = 8
		case .R_X86_64_TPOFF64:
			field_size = 8
		case .R_X86_64_PC32, .R_X86_64_PLT32, .R_X86_64_32, .R_X86_64_32S, .R_X86_64_TPOFF32:
			field_size = 4
		case .R_X86_64_GOTPCREL, .R_X86_64_GOTPCRELX, .R_X86_64_REX_GOTPCRELX:
			field_size = 4
		case:
			return Unsupported_Relocation{kind = reloc.kind}
		}
		if u64(reloc.offset) + u64(field_size) > u64(len(atom.bytes)) {
			return Relocation_Out_Of_Atom{input = u32(input_index), symbol = reloc.symbol, atom = u32(atom_index), offset = reloc.offset}
		}
		target_symbol := symbols[reloc.symbol]
		if !target_symbol.defined {
			return Undefined_Symbol{name = input.symbols[reloc.symbol].name}
		}

		target := i64(target_symbol.address) + reloc.addend
		place := i64(atom_address) + i64(reloc.offset)
		value := target
		if target_symbol.is_dynamic {
			name := input.symbols[reloc.symbol].name
			#partial switch reloc.kind {
			case .R_X86_64_PC32, .R_X86_64_PLT32:
				address, found := plt_address(fixups^, name)
				if !found {
					return Undefined_Symbol{name = name}
				}
				value = i64(address) + reloc.addend - place
			case .R_X86_64_GOTPCREL, .R_X86_64_GOTPCRELX, .R_X86_64_REX_GOTPCRELX:
				address, found := dyn_got_address(fixups^, name)
				if !found {
					return Undefined_Symbol{name = name}
				}
				value = i64(address) + reloc.addend - place
			case .R_X86_64_64:
				value = reloc.addend
			case:
				return Unsupported_Relocation{kind = reloc.kind}
			}
		} else {
			#partial switch reloc.kind {
			case .R_X86_64_PC32, .R_X86_64_PLT32:
				value = target - place
			case .R_X86_64_GOTPCREL:
				key := Got_Key {
					input  = u32(input_index),
					symbol = reloc.symbol,
				}
				index, found := fixups.local_got[key]
				if !found {
					return Unsupported_Relocation{kind = reloc.kind}
				}
				value = i64(fixups.local_base) + i64(index) * 8 + reloc.addend - place
			case .R_X86_64_GOTPCRELX, .R_X86_64_REX_GOTPCRELX:
				field_index := int(place - i64(layout.text_start))
				if apply_relax(load_bytes, field_index, reloc.kind) {
					value = target - place
				} else {
					key := Got_Key {
						input  = u32(input_index),
						symbol = reloc.symbol,
					}
					index, found := fixups.local_got[key]
					if !found {
						return Unsupported_Relocation{kind = reloc.kind}
					}
					value = i64(fixups.local_base) + i64(index) * 8 + reloc.addend - place
				}
			case .R_X86_64_TPOFF32:
				if target_symbol.section != .Tdata && target_symbol.section != .Tbss {
					return Relocation_Not_Thread_Local{input = u32(input_index), symbol = reloc.symbol, atom = u32(atom_index), offset = reloc.offset}
				}
				value = target - i64(layout.thread_pointer)
			case .R_X86_64_TPOFF64:
				if target_symbol.section != .Tdata && target_symbol.section != .Tbss {
					return Relocation_Not_Thread_Local{input = u32(input_index), symbol = reloc.symbol, atom = u32(atom_index), offset = reloc.offset}
				}
				value = target - i64(layout.thread_pointer)
			}
		}
		if !fits_field(reloc.kind, value) {
			return Relocation_Overflow{input = u32(input_index), symbol = reloc.symbol, atom = u32(atom_index), offset = reloc.offset, value = value}
		}

		field_start := place - i64(layout.text_start)
		store_little_endian(load_bytes[field_start:field_start + i64(field_size)], u64(value))
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

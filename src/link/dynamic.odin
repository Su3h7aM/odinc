package link

import "core:mem"
import "oc:elf"

// PT_INTERP of the Linux x86-64 system loader. The gABI leaves the path implementation-defined; this is the glibc loader's
// path, so foreign libraries built against glibc get their DT_NEEDED entries loaded by it.
INTERPRETER :: "/lib64/ld-linux-x86-64.so.2"

Fixups :: struct {
	allocator:    mem.Allocator,
	local_got:    map[Got_Key]int,
	local_order:  [dynamic]Got_Key,
	dyn_index:    map[string]int,
	dyns:         [dynamic]Dynamic_Use,
	absolutes:    [dynamic]Absolute_Use,
	local_base:   u64,
	plt_base:     u64,
	gotplt_base:  u64,
	dynsym_base:  u64,
	dynstr_base:  u64,
	hash_base:    u64,
	rela_base:    u64,
	relaplt_base: u64,
	dynamic_base: u64,
	interp_base:  u64,
	dynstr_size:  int,
	rela_count:   int,
}

Got_Key :: struct {
	input:  u32,
	symbol: u32,
}

Dynamic_Use :: struct {
	name: string,
	plt:  bool,
	got:  bool,
}

Absolute_Use :: struct {
	input:  u32,
	atom:   u32,
	offset: u32,
	addend: i64,
	name:   string,
}

fixups_init :: proc(allocator: mem.Allocator) -> Fixups {
	return Fixups {
		allocator = allocator,
		local_got = make(map[Got_Key]int, allocator = allocator),
		local_order = make([dynamic]Got_Key, allocator),
		dyn_index = make(map[string]int, allocator = allocator),
		dyns = make([dynamic]Dynamic_Use, allocator),
		absolutes = make([dynamic]Absolute_Use, allocator),
	}
}

fixups_destroy :: proc(fixups: ^Fixups) {
	if fixups == nil {
		return
	}
	delete(fixups.local_got)
	delete(fixups.local_order)
	delete(fixups.dyn_index)
	delete(fixups.dyns)
	delete(fixups.absolutes)
	fixups^ = {}
}

dynamic_symbol :: proc(symbol: Symbol, choices: map[string]Symbol_Choice, provided: map[string]bool) -> bool {
	if symbol.binding == .Local || len(symbol.name) == 0 || symbol.name in choices {
		return false
	}
	return symbol.name in provided
}

plan_fixups :: proc(inputs: []Input, choices: map[string]Symbol_Choice, provided: map[string]bool, fixups: ^Fixups) {
	for input, input_index in inputs {
		for atom, atom_index in input.atoms {
			if atom.discarded {
				continue
			}
			for reloc in atom.relocs {
				if int(reloc.symbol) >= len(input.symbols) {
					continue
				}
				symbol := input.symbols[reloc.symbol]
				is_dynamic := dynamic_symbol(symbol, choices, provided)
				#partial switch reloc.kind {
				case .R_X86_64_PLT32, .R_X86_64_PC32:
					if is_dynamic {
						note_dynamic(fixups, symbol.name, true, false)
					}
				case .R_X86_64_GOTPCREL, .R_X86_64_GOTPCRELX, .R_X86_64_REX_GOTPCRELX:
					if is_dynamic {
						note_dynamic(fixups, symbol.name, false, true)
					} else if symbol_is_defined(symbol, choices) && !can_relax(atom.bytes, int(reloc.offset), reloc.kind) {
						key := Got_Key {
							input  = u32(input_index),
							symbol = reloc.symbol,
						}
						if key not_in fixups.local_got {
							fixups.local_got[key] = len(fixups.local_order)
							append(&fixups.local_order, key)
						}
					}
				case .R_X86_64_64:
					if is_dynamic {
						note_dynamic(fixups, symbol.name, false, false)
						append(
							&fixups.absolutes,
							Absolute_Use{input = u32(input_index), atom = u32(atom_index), offset = reloc.offset, addend = reloc.addend, name = symbol.name},
						)
					}
				}
			}
		}
	}
}

note_dynamic :: proc(fixups: ^Fixups, name: string, plt, got: bool) {
	if index, found := fixups.dyn_index[name]; found {
		if plt {
			fixups.dyns[index].plt = true
		}
		if got {
			fixups.dyns[index].got = true
		}
		return
	}
	fixups.dyn_index[name] = len(fixups.dyns)
	append(&fixups.dyns, Dynamic_Use{name = name, plt = plt, got = got})
}

symbol_is_defined :: proc(symbol: Symbol, choices: map[string]Symbol_Choice) -> bool {
	if symbol.binding == .Local {
		return symbol.absolute || symbol.atom != ATOM_UNDEFINED
	}
	return symbol.name in choices
}

rodata_tail_size :: proc(fixups: Fixups, needed: []string) -> u64 {
	if len(needed) == 0 && len(fixups.dyns) == 0 {
		return 0
	}
	dyn_count := 1 + len(fixups.dyns)
	names := 1
	for use in fixups.dyns {
		names += len(use.name) + 1
	}
	for name in needed {
		names += len(name) + 1
	}
	plt_count, got_count := dynamic_counts(fixups)
	rod := align_up(u64(len(INTERPRETER) + 1), 8)
	rod += u64(dyn_count) * size_of(elf.Symbol_Entry)
	rod += u64(names)
	rod = align_up(rod, 4)
	rod += 4 * (2 + 2 * u64(dyn_count))
	rod = align_up(rod, 8)
	rod += u64(got_count + len(fixups.absolutes)) * size_of(elf.Rela_Entry)
	rod += u64(plt_count) * size_of(elf.Rela_Entry)
	return rod
}

data_tail_size :: proc(fixups: Fixups, needed: []string) -> u64 {
	plt_count, got_count := dynamic_counts(fixups)
	size := u64(len(fixups.local_order)) * 8
	size += u64(got_count) * 8
	if plt_count > 0 {
		size += u64(3 + plt_count) * 8
	}
	if len(needed) == 0 && len(fixups.dyns) == 0 {
		return size
	}
	size = align_up(size, 8)
	entries := len(needed) + 8
	if got_count + len(fixups.absolutes) > 0 {
		entries += 3
	}
	if plt_count > 0 {
		entries += 4
	}
	return size + u64(entries) * size_of(elf.Dynamic_Entry)
}

text_tail_size :: proc(fixups: Fixups) -> u64 {
	plt_count, _ := dynamic_counts(fixups)
	if plt_count == 0 {
		return 0
	}
	return 16 + u64(plt_count) * 16
}

dynamic_counts :: proc(fixups: Fixups) -> (plt, got: int) {
	for use in fixups.dyns {
		if use.plt {
			plt += 1
		}
		if use.got {
			got += 1
		}
	}
	return
}

assign_fixup_addresses :: proc(fixups: ^Fixups, layout: Layout, needed: []string) {
	fixups.plt_base = layout.text_tail
	cursor := layout.data_tail
	fixups.local_base = cursor
	cursor += u64(len(fixups.local_order)) * 8
	_, got_count := dynamic_counts(fixups^)
	cursor += u64(got_count) * 8
	plt_count, _ := dynamic_counts(fixups^)
	fixups.gotplt_base = cursor
	if plt_count > 0 {
		cursor += u64(3 + plt_count) * 8
	}
	if len(needed) > 0 || len(fixups.dyns) > 0 {
		fixups.dynamic_base = align_up(cursor, 8)
		rod := layout.rodata_tail
		fixups.interp_base = rod
		rod = align_up(rod + u64(len(INTERPRETER) + 1), 8)
		fixups.dynsym_base = rod
		rod += u64(1 + len(fixups.dyns)) * size_of(elf.Symbol_Entry)
		fixups.dynstr_base = rod
		names := 1
		for use in fixups.dyns {
			names += len(use.name) + 1
		}
		for name in needed {
			names += len(name) + 1
		}
		fixups.dynstr_size = names
		rod += u64(names)
		rod = align_up(rod, 4)
		fixups.hash_base = rod
		rod += 4 * (2 + 2 * u64(1 + len(fixups.dyns)))
		rod = align_up(rod, 8)
		fixups.rela_base = rod
		fixups.rela_count = got_count + len(fixups.absolutes)
		rod += u64(fixups.rela_count) * size_of(elf.Rela_Entry)
		fixups.relaplt_base = rod
	}
}

can_relax :: proc(code: []byte, offset: int, kind: elf.R_X86_64) -> bool {
	_, ok := relax_opcode(code, offset, kind)
	return ok
}

relax_opcode :: proc(code: []byte, offset: int, kind: elf.R_X86_64) -> (patch: u16, ok: bool) {
	if kind == .R_X86_64_GOTPCRELX {
		if offset < 2 || offset > len(code) {
			return
		}
		last := u16(code[offset - 2]) << 8 | u16(code[offset - 1])
		switch last {
		case 0xff15:
			return 0x40e8, true
		case 0xff25:
			return 0x40e9, true
		}
		return
	}
	if kind != .R_X86_64_REX_GOTPCRELX || offset < 3 || offset > len(code) {
		return
	}
	last := u32(code[offset - 3]) << 16 | u32(code[offset - 2]) << 8 | u32(code[offset - 1])
	switch last {
	case 0x488b05, 0x4c8b05:
		return 0x8d05, true
	case 0x488b0d, 0x4c8b0d:
		return 0x8d0d, true
	case 0x488b15, 0x4c8b15:
		return 0x8d15, true
	case 0x488b1d, 0x4c8b1d:
		return 0x8d1d, true
	case 0x488b25, 0x4c8b25:
		return 0x8d25, true
	case 0x488b2d, 0x4c8b2d:
		return 0x8d2d, true
	case 0x488b35, 0x4c8b35:
		return 0x8d35, true
	case 0x488b3d, 0x4c8b3d:
		return 0x8d3d, true
	}
	return
}

apply_relax :: proc(image: []byte, field: int, kind: elf.R_X86_64) -> bool {
	patch, ok := relax_opcode(image, field, kind)
	if !ok {
		return false
	}
	image[field - 2] = u8(patch >> 8)
	image[field - 1] = u8(patch)
	return true
}

plt_address :: proc(fixups: Fixups, name: string) -> (u64, bool) {
	index, found := fixups.dyn_index[name]
	if !found || !fixups.dyns[index].plt {
		return 0, false
	}
	ordinal := 0
	for use, position in fixups.dyns {
		if position == index {
			break
		}
		if use.plt {
			ordinal += 1
		}
	}
	return fixups.plt_base + 16 + u64(ordinal) * 16, true
}

dyn_got_address :: proc(fixups: Fixups, name: string) -> (u64, bool) {
	index, found := fixups.dyn_index[name]
	if !found || !fixups.dyns[index].got {
		return 0, false
	}
	ordinal := 0
	for use, position in fixups.dyns {
		if position == index {
			break
		}
		if use.got {
			ordinal += 1
		}
	}
	return fixups.local_base + u64(len(fixups.local_order) + ordinal) * 8, true
}

fill_dynamic :: proc(addresses: [][]u64, symbols: [][]Resolved_Symbol, load_bytes: []byte, layout: Layout, fixups: Fixups, needed: []string) {
	base := int(layout.text_start)
	if text_tail_size(fixups) > 0 {
		write_plt(load_bytes[int(fixups.plt_base) - base:], fixups)
	}
	for key, index in fixups.local_order {
		resolved := symbols[key.input][key.symbol]
		store_little_endian(load_bytes[int(fixups.local_base) - base + index * 8:][:8], resolved.address)
	}
	if len(needed) == 0 && len(fixups.dyns) == 0 {
		return
	}
	write_interp(load_bytes[int(fixups.interp_base) - base:])
	write_dynsym(load_bytes[int(fixups.dynsym_base) - base:], load_bytes[int(fixups.dynstr_base) - base:], fixups, needed)
	write_hash(load_bytes[int(fixups.hash_base) - base:], fixups)
	write_relocations(load_bytes, layout, fixups, addresses)
	write_gotplt(load_bytes[int(fixups.gotplt_base) - base:], fixups)
	write_dynamic_array(load_bytes[int(fixups.dynamic_base) - base:], fixups, needed)
}

write_plt :: proc(bytes: []byte, fixups: Fixups) {
	if len(bytes) < 16 {
		return
	}
	header := [16]u8{0xff, 0x35, 0, 0, 0, 0, 0xff, 0x25, 0, 0, 0, 0, 0x0f, 0x1f, 0x40, 0x00}
	copy(bytes, header[:])
	store_little_endian(bytes[2:6], u64(i64(fixups.gotplt_base + 8) - i64(fixups.plt_base + 6)))
	store_little_endian(bytes[8:12], u64(i64(fixups.gotplt_base + 16) - i64(fixups.plt_base + 12)))
	ordinal := 0
	for use in fixups.dyns {
		if !use.plt {
			continue
		}
		entry := 16 + ordinal * 16
		slot := fixups.gotplt_base + u64(3 + ordinal) * 8
		bytes[entry] = 0xff
		bytes[entry + 1] = 0x25
		store_little_endian(bytes[entry + 2:entry + 6], u64(i64(slot) - i64(fixups.plt_base + u64(entry) + 6)))
		bytes[entry + 6] = 0x68
		store_little_endian(bytes[entry + 7:entry + 11], u64(ordinal))
		bytes[entry + 11] = 0xe9
		store_little_endian(bytes[entry + 12:entry + 16], u64(i64(fixups.plt_base) - i64(fixups.plt_base + u64(entry) + 16)))
		ordinal += 1
	}
}

write_gotplt :: proc(bytes: []byte, fixups: Fixups) {
	plt_count, _ := dynamic_counts(fixups)
	if plt_count == 0 || len(bytes) < (3 + plt_count) * 8 {
		return
	}
	store_little_endian(bytes[:8], fixups.dynamic_base)
}

write_interp :: proc(bytes: []byte) {
	copy(bytes, INTERPRETER)
	if len(bytes) > len(INTERPRETER) {
		bytes[len(INTERPRETER)] = 0
	}
}

write_dynsym :: proc(symtab, strtab: []byte, fixups: Fixups, needed: []string) {
	cursor := 0
	put_string(strtab, &cursor, "")
	for name in needed {
		put_string(strtab, &cursor, name)
	}
	for use, index in fixups.dyns {
		name_offset := put_string(strtab, &cursor, use.name)
		entry_at := (index + 1) * size_of(elf.Symbol_Entry)
		entry := elf.Symbol_Entry {
			st_name = u32le(name_offset),
			st_info = u8(elf.STB.STB_GLOBAL) << 4 | u8(elf.STT.STT_NOTYPE),
		}
		mem.copy(&symtab[entry_at], &entry, size_of(elf.Symbol_Entry))
	}
}

put_string :: proc(strtab: []byte, cursor: ^int, value: string) -> int {
	offset := cursor^
	copy(strtab[offset:], value)
	strtab[offset + len(value)] = 0
	cursor^ = offset + len(value) + 1
	return offset
}

write_hash :: proc(table: []byte, fixups: Fixups) {
	count := 1 + len(fixups.dyns)
	store_u32(table, 0, u32(count))
	store_u32(table, 1, u32(count))
	for use, index in fixups.dyns {
		hash := elf_hash(use.name) % u32(count)
		bucket := 2 + int(hash)
		chain := 2 + count + index + 1
		store_u32(table, chain, load_u32(table, bucket))
		store_u32(table, bucket, u32(index + 1))
	}
}

elf_hash :: proc(name: string) -> u32 {
	hash: u32
	for character in name {
		hash = (hash << 4) + u32(character)
		high := hash & 0xf000_0000
		if high != 0 {
			hash ~= high >> 24
		}
		hash &= ~high
	}
	return hash
}

write_relocations :: proc(load_bytes: []byte, layout: Layout, fixups: Fixups, addresses: [][]u64) {
	base := int(layout.text_start)
	rela := load_bytes[int(fixups.rela_base) - base:]
	index := 0
	got_ordinal := 0
	for use, dyn_index in fixups.dyns {
		if !use.got {
			continue
		}
		slot := fixups.local_base + u64(len(fixups.local_order) + got_ordinal) * 8
		write_rela(rela[index * size_of(elf.Rela_Entry):], slot, u32(dyn_index + 1), .R_X86_64_GLOB_DAT, 0)
		index += 1
		got_ordinal += 1
	}
	for absolute in fixups.absolutes {
		place := addresses[absolute.input][absolute.atom] + u64(absolute.offset)
		dyn_index := fixups.dyn_index[absolute.name]
		write_rela(rela[index * size_of(elf.Rela_Entry):], place, u32(dyn_index + 1), .R_X86_64_64, absolute.addend)
		index += 1
	}
	plt := load_bytes[int(fixups.relaplt_base) - base:]
	ordinal := 0
	for use, dyn_index in fixups.dyns {
		if !use.plt {
			continue
		}
		slot := fixups.gotplt_base + u64(3 + ordinal) * 8
		write_rela(plt[ordinal * size_of(elf.Rela_Entry):], slot, u32(dyn_index + 1), .R_X86_64_JUMP_SLOT, 0)
		ordinal += 1
	}
}

write_rela :: proc(bytes: []byte, offset: u64, symbol: u32, kind: elf.R_X86_64, addend: i64) {
	entry := elf.Rela_Entry {
		r_offset = u64le(offset),
		r_info   = u64le(u64(symbol) << 32 | u64(kind)),
		r_addend = i64le(addend),
	}
	mem.copy(&bytes[0], &entry, size_of(elf.Rela_Entry))
}

write_dynamic_array :: proc(bytes: []byte, fixups: Fixups, needed: []string) {
	cursor := 1
	entries := make([dynamic]elf.Dynamic_Entry, fixups.allocator)
	defer delete(entries)
	for name in needed {
		append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_NEEDED), d_val = u64le(cursor)})
		cursor += len(name) + 1
	}
	for use in fixups.dyns {
		cursor += len(use.name) + 1
	}
	append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_SYMTAB), d_val = u64le(fixups.dynsym_base)})
	append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_SYMENT), d_val = u64le(size_of(elf.Symbol_Entry))})
	append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_STRTAB), d_val = u64le(fixups.dynstr_base)})
	append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_STRSZ), d_val = u64le(fixups.dynstr_size)})
	append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_HASH), d_val = u64le(fixups.hash_base)})
	if fixups.rela_count > 0 {
		append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_RELA), d_val = u64le(fixups.rela_base)})
		append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_RELASZ), d_val = u64le(fixups.rela_count * size_of(elf.Rela_Entry))})
		append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_RELAENT), d_val = u64le(size_of(elf.Rela_Entry))})
	}
	plt_count, _ := dynamic_counts(fixups)
	if plt_count > 0 {
		append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_PLTGOT), d_val = u64le(fixups.gotplt_base)})
		append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_JMPREL), d_val = u64le(fixups.relaplt_base)})
		append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_PLTRELSZ), d_val = u64le(plt_count * size_of(elf.Rela_Entry))})
		append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_PLTREL), d_val = u64le(elf.DT_RELA)})
	}
	append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_FLAGS), d_val = u64le(elf.DF_BIND_NOW)})
	append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_FLAGS_1), d_val = u64le(elf.DF_1_NOW)})
	append(&entries, elf.Dynamic_Entry{d_tag = i64le(elf.DT_NULL), d_val = 0})
	mem.copy(&bytes[0], raw_data(entries), len(entries) * size_of(elf.Dynamic_Entry))
}

store_u32 :: proc(bytes: []byte, index: int, value: u32) {
	store_little_endian(bytes[index * 4:][:4], u64(value))
}

load_u32 :: proc(bytes: []byte, index: int) -> u32 {
	value: u32
	for shift in 0 ..< 4 {
		value |= u32(bytes[index * 4 + shift]) << uint(8 * shift)
	}
	return value
}

configure_dynamic_program :: proc(builder: ^elf.Executable_Builder, layout: Layout, fixups: Fixups, needed: []string) {
	if len(needed) == 0 && len(fixups.dyns) == 0 {
		return
	}
	elf.executable_load_headers(builder, BASE)
	elf.executable_set_interpreter(builder, fixups.interp_base, u64(len(INTERPRETER) + 1))
	elf.executable_set_dynamic(builder, fixups.dynamic_base, u64(data_tail_size(fixups, needed) - (fixups.dynamic_base - layout.data_tail)))
}

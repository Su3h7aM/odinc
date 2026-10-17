package link

import "core:mem"
import "core:strings"
import "oc:elf"

/*
	Frees slices and cloned names owned by `input`.  A zero input is a no-op.
*/
input_destroy :: proc(input: ^Input, allocator: mem.Allocator) {
	if input == nil {
		return
	}
	for &atom in input.atoms {
		delete(atom.bytes, allocator)
		delete(atom.relocs, allocator)
	}
	delete(input.atoms, allocator)
	for &symbol in input.symbols {
		delete(symbol.name, allocator)
	}
	delete(input.symbols, allocator)
	for &comdat in input.comdats {
		delete(comdat.signature, allocator)
		delete(comdat.atoms, allocator)
	}
	delete(input.comdats, allocator)
	input^ = {}
}

/*
	Reads an ELF64 little-endian x86-64 relocatable object into an `Input`.
	The caller owns `input` and frees it with `input_destroy`.  Section and
	symbol names are cloned.  `.note.GNU-stack` is ignored.  `SHN_COMMON`
	becomes a tentative `.Bss` atom.  A `GRP_COMDAT` group is recorded so
	`link` can keep the first copy.
*/
read_object :: proc(data: []byte, allocator: mem.Allocator) -> (input: Input, err: Link_Error) {
	defer if err != nil {
		input_destroy(&input, allocator)
	}

	header, header_ok := read_pod(data, 0, elf.File_Header)
	if !header_ok || string(header.ident[:4]) != elf.ELF_MAGIC {
		return {}, Malformed_File{detail = "not an ELF file"}
	}
	if header.ident[elf.EI_CLASS] != elf.ELFCLASS64 || header.ident[elf.EI_DATA] != elf.ELFDATA2LSB {
		return {}, Malformed_File{detail = "not ELF64 little-endian"}
	}
	if header.e_machine != .EM_X86_64 || header.e_type != .ET_REL {
		return {}, Malformed_File{detail = "not an x86-64 relocatable object"}
	}
	if u16(header.e_shentsize) != size_of(elf.Section_Header) || u64(header.e_shoff) == 0 {
		return {}, Malformed_File{detail = "missing section headers"}
	}

	section_count := int(header.e_shnum)
	if section_count == 0 {
		return {}, Malformed_File{detail = "extended section count is not supported"}
	}
	sections := make([]elf.Section_Header, section_count, allocator) or_return
	defer delete(sections, allocator)
	section_base := int(header.e_shoff)
	for index in 0 ..< section_count {
		section, ok := read_pod(data, section_base + index * size_of(elf.Section_Header), elf.Section_Header)
		if !ok {
			return {}, Malformed_File{detail = "truncated section headers"}
		}
		sections[index] = section
	}

	names_index := int(header.e_shstrndx)
	if names_index < 0 || names_index >= section_count {
		return {}, Malformed_File{detail = "missing section name table"}
	}
	names := section_bytes(data, sections[names_index]) or_return

	atom_of_section := make([]int, section_count, allocator) or_return
	defer delete(atom_of_section, allocator)
	for index in 0 ..< section_count {
		atom_of_section[index] = -1
	}

	atoms := make([dynamic]Atom, allocator) or_return
	defer if err != nil {
		for atom in atoms {
			delete(atom.bytes, allocator)
			delete(atom.relocs, allocator)
		}
		delete(atoms)
	}

	for section, index in sections {
		kind, keep := atom_kind(data, names, section)
		if !keep {
			continue
		}
		if .SHF_COMPRESSED in elf.flags_from_section_mask(u64(section.sh_flags)) {
			return {}, Malformed_File{detail = "compressed section"}
		}
		atom := Atom {
			section = kind,
			align   = u32(max(section.sh_addralign, 1)),
			size    = u64(section.sh_size),
		}
		if kind != .Bss && kind != .Tbss {
			bytes := section_bytes(data, section) or_return
			atom.bytes = make([]byte, len(bytes), allocator) or_return
			copy(atom.bytes, bytes)
		}
		atom_of_section[index] = len(atoms)
		append(&atoms, atom)
	}

	symbol_section := -1
	for section, index in sections {
		if section.sh_type == .SHT_SYMTAB {
			symbol_section = index
			break
		}
	}
	if symbol_section < 0 {
		return {}, Malformed_File{detail = "missing symbol table"}
	}
	symbol_header := sections[symbol_section]
	if u64(symbol_header.sh_entsize) != size_of(elf.Symbol_Entry) || u32(symbol_header.sh_link) >= u32(section_count) {
		return {}, Malformed_File{detail = "bad symbol table"}
	}
	symbol_bytes := section_bytes(data, symbol_header) or_return
	if len(symbol_bytes) % size_of(elf.Symbol_Entry) != 0 {
		return {}, Malformed_File{detail = "truncated symbol table"}
	}
	string_bytes := section_bytes(data, sections[symbol_header.sh_link]) or_return
	symbol_count := len(symbol_bytes) / size_of(elf.Symbol_Entry)
	symbols := make([]Symbol, symbol_count, allocator) or_return
	defer if err != nil {
		for symbol in symbols {
			delete(symbol.name, allocator)
		}
		delete(symbols, allocator)
	}

	for index in 0 ..< symbol_count {
		entry, ok := read_pod(symbol_bytes, index * size_of(elf.Symbol_Entry), elf.Symbol_Entry)
		if !ok {
			return {}, Malformed_File{detail = "truncated symbol"}
		}
		name := cstring_at(string_bytes, int(entry.st_name))
		cloned := strings.clone(name, allocator) or_return
		symbol := Symbol {
			name    = cloned,
			atom    = ATOM_UNDEFINED,
			offset  = u64(entry.st_value),
			binding = binding_of(entry.st_info),
		}
		section_index := u16(entry.st_shndx)
		kind := entry.st_info & 0xf
		if kind == u8(elf.STT.STT_FILE) {
			symbols[index] = symbol
			continue
		}
		if section_index == u16(elf.SHN_UNDEF) {
			symbols[index] = symbol
			continue
		}
		if section_index == u16(elf.SHN_ABS) {
			symbol.absolute = true
			symbols[index] = symbol
			continue
		}
		if section_index == u16(elf.SHN_COMMON) {
			common := Atom {
				section = .Bss,
				align   = u32(max(entry.st_value, 1)),
				size    = u64(entry.st_size),
			}
			if u64(entry.st_value) > u64(max(u32)) {
				delete(cloned, allocator)
				return {}, Malformed_File{detail = "common alignment does not fit"}
			}
			symbol.atom = u32(len(atoms))
			symbol.offset = 0
			symbol.tentative = true
			append(&atoms, common)
			symbols[index] = symbol
			continue
		}
		if section_index == 0xffff || int(section_index) >= section_count {
			delete(cloned, allocator)
			return {}, Malformed_File{detail = "symbol section index"}
		}
		atom_index := atom_of_section[section_index]
		if atom_index >= 0 {
			symbol.atom = u32(atom_index)
		}
		symbols[index] = symbol
	}

	for section in sections {
		if u32(section.sh_type) == 9 {
			target := int(section.sh_info)
			if target >= 0 && target < section_count && atom_of_section[target] >= 0 {
				return {}, Malformed_File{detail = "SHT_REL"}
			}
		}
		if section.sh_type != .SHT_RELA {
			continue
		}
		target := int(section.sh_info)
		if target < 0 || target >= section_count || atom_of_section[target] < 0 {
			continue
		}
		if u64(section.sh_entsize) != size_of(elf.Rela_Entry) {
			return {}, Malformed_File{detail = "bad relocation entry"}
		}
		rela_bytes := section_bytes(data, section) or_return
		if len(rela_bytes) % size_of(elf.Rela_Entry) != 0 {
			return {}, Malformed_File{detail = "truncated relocations"}
		}
		count := len(rela_bytes) / size_of(elf.Rela_Entry)
		relocs := make([]Relocation, count, allocator) or_return
		for rela_index in 0 ..< count {
			entry, ok := read_pod(rela_bytes, rela_index * size_of(elf.Rela_Entry), elf.Rela_Entry)
			if !ok {
				delete(relocs, allocator)
				return {}, Malformed_File{detail = "truncated relocation"}
			}
			if u64(entry.r_offset) > u64(max(u32)) {
				delete(relocs, allocator)
				return {}, Malformed_File{detail = "relocation offset"}
			}
			symbol_index := u32(u64(entry.r_info) >> 32)
			if int(symbol_index) >= symbol_count {
				delete(relocs, allocator)
				return {}, Malformed_File{detail = "relocation symbol"}
			}
			relocs[rela_index] = Relocation {
				offset = u32(entry.r_offset),
				symbol = symbol_index,
				kind   = elf.R_X86_64(u32(u64(entry.r_info) & 0xffff_ffff)),
				addend = i64(entry.r_addend),
			}
		}
		atoms[atom_of_section[target]].relocs = relocs
	}

	comdats := make([dynamic]Comdat, allocator) or_return
	defer if err != nil {
		for comdat in comdats {
			delete(comdat.signature, allocator)
			delete(comdat.atoms, allocator)
		}
		delete(comdats)
	}
	for section in sections {
		if u32(section.sh_type) != elf.SHT_GROUP {
			continue
		}
		group := section_bytes(data, section) or_return
		if len(group) < 4 || len(group) % 4 != 0 {
			return {}, Malformed_File{detail = "bad section group"}
		}
		flags := u32(group[0]) | u32(group[1]) << 8 | u32(group[2]) << 16 | u32(group[3]) << 24
		if flags & elf.GRP_COMDAT == 0 {
			continue
		}
		signature_index := int(section.sh_info)
		if signature_index < 0 || signature_index >= symbol_count {
			return {}, Malformed_File{detail = "bad COMDAT signature"}
		}
		members := make([dynamic]u32, allocator) or_return
		for cursor := 4; cursor < len(group); cursor += 4 {
			member := u32(group[cursor]) | u32(group[cursor + 1]) << 8 | u32(group[cursor + 2]) << 16 | u32(group[cursor + 3]) << 24
			if int(member) >= section_count {
				delete(members)
				return {}, Malformed_File{detail = "bad COMDAT member"}
			}
			atom_index := atom_of_section[member]
			if atom_index >= 0 {
				append(&members, u32(atom_index))
			}
		}
		signature := strings.clone(symbols[signature_index].name, allocator) or_return
		owned := make([]u32, len(members), allocator) or_return
		copy(owned, members[:])
		delete(members)
		append(&comdats, Comdat{signature = signature, atoms = owned})
	}

	input.atoms = make([]Atom, len(atoms), allocator) or_return
	copy(input.atoms, atoms[:])
	delete(atoms)
	atoms = nil
	input.symbols = symbols
	symbols = nil
	input.comdats = make([]Comdat, len(comdats), allocator) or_return
	copy(input.comdats, comdats[:])
	delete(comdats)
	comdats = nil
	return input, nil
}

atom_kind :: proc(data: []byte, names: []byte, section: elf.Section_Header) -> (kind: Section_Kind, keep: bool) {
	name := cstring_at(names, int(section.sh_name))
	if name == ".note.GNU-stack" {
		return
	}
	flags := elf.flags_from_section_mask(u64(section.sh_flags))
	if .SHF_EXCLUDE in flags || .SHF_ALLOC not_in flags {
		return
	}
	section_type := u32(section.sh_type)
	if section.sh_type == .SHT_NULL ||
	   section.sh_type == .SHT_SYMTAB ||
	   section.sh_type == .SHT_STRTAB ||
	   section.sh_type == .SHT_RELA ||
	   section_type == elf.SHT_GROUP ||
	   section_type == elf.SHT_NOTE ||
	   section_type == elf.SHT_HASH ||
	   section_type == elf.SHT_DYNAMIC ||
	   section_type == elf.SHT_DYNSYM {
		return
	}
	if section.sh_size == 0 && section.sh_type != .SHT_NOBITS {
		return
	}
	if .SHF_TLS in flags {
		if section.sh_type == .SHT_NOBITS {
			return .Tbss, true
		}
		return .Tdata, true
	}
	if .SHF_EXECINSTR in flags {
		return .Text, true
	}
	if section.sh_type == .SHT_NOBITS {
		return .Bss, true
	}
	if .SHF_WRITE in flags {
		return .Data, true
	}
	return .Rodata, true
}

binding_of :: proc(info: u8) -> Binding {
	switch info >> 4 {
	case u8(elf.STB.STB_LOCAL):
		return .Local
	case u8(elf.STB.STB_WEAK):
		return .Weak
	case:
		return .Global
	}
}

section_bytes :: proc(data: []byte, section: elf.Section_Header) -> (bytes: []byte, err: Link_Error) {
	if section.sh_type == .SHT_NOBITS {
		return nil, nil
	}
	start := int(section.sh_offset)
	end := start + int(section.sh_size)
	if u64(section.sh_size) > u64(max(int)) || start < 0 || end > len(data) || end < start {
		return nil, Malformed_File{detail = "section exceeds the file"}
	}
	return data[start:end], nil
}

cstring_at :: proc(bytes: []byte, offset: int) -> string {
	if offset < 0 || offset >= len(bytes) {
		return ""
	}
	end := offset
	for end < len(bytes) && bytes[end] != 0 {
		end += 1
	}
	return string(bytes[offset:end])
}

read_pod :: proc(data: []byte, offset: int, $T: typeid) -> (value: T, ok: bool) {
	if offset < 0 || offset + size_of(T) > len(data) {
		return
	}
	mem.copy(&value, raw_data(data[offset:]), size_of(T))
	return value, true
}

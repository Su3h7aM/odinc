package link

import "core:mem"
import "core:strings"
import "oc:elf"

/*
	Defined dynamic symbols of one shared library. `needed` is the
	`DT_NEEDED` string for a library without `DT_SONAME`; the soname wins.
*/
Shared_Library :: struct {
	needed:    string,
	symbols:   map[string]bool,
	allocator: mem.Allocator,
	// Linked only when a symbol it defines is referenced, like `ld --as-needed`.
	as_needed: bool,
}

/*
	Reads `DT_SONAME` and the defined `.dynsym` entries of an ELF64 shared object.
	The caller frees the result with `shared_library_destroy`.
*/
shared_library_read :: proc(data: []byte, needed: string, allocator: mem.Allocator) -> (library: Shared_Library, err: Link_Error) {
	defer if err != nil {
		shared_library_destroy(&library)
	}
	header, ok := read_pod(data, 0, elf.File_Header)
	if !ok || string(header.ident[:4]) != elf.ELF_MAGIC || header.e_machine != .EM_X86_64 || header.e_type != .ET_DYN {
		return {}, Malformed_File{detail = "not an x86-64 shared object"}
	}
	if int(header.e_shnum) == 0 || u64(header.e_shoff) == 0 {
		return {}, Malformed_File{detail = "shared object has no section headers"}
	}
	section_count := int(header.e_shnum)
	sections := make([]elf.Section_Header, section_count, allocator) or_return
	defer delete(sections, allocator)
	base := int(header.e_shoff)
	for index in 0 ..< section_count {
		section, section_ok := read_pod(data, base + index * size_of(elf.Section_Header), elf.Section_Header)
		if !section_ok {
			return {}, Malformed_File{detail = "truncated shared object"}
		}
		sections[index] = section
	}

	library.allocator = allocator
	library.symbols = make(map[string]bool, allocator = allocator)
	soname := ""
	for section in sections {
		if u32(section.sh_type) != elf.SHT_DYNAMIC {
			continue
		}
		bytes := section_bytes(data, section) or_return
		if len(bytes) % size_of(elf.Dynamic_Entry) != 0 {
			return {}, Malformed_File{detail = "bad dynamic section"}
		}
		string_section := int(section.sh_link)
		strings_bytes: []byte
		if string_section >= 0 && string_section < section_count {
			strings_bytes = section_bytes(data, sections[string_section]) or_return
		}
		for cursor := 0; cursor < len(bytes); cursor += size_of(elf.Dynamic_Entry) {
			entry, entry_ok := read_pod(bytes, cursor, elf.Dynamic_Entry)
			if !entry_ok {
				return {}, Malformed_File{detail = "truncated dynamic entry"}
			}
			if i64(entry.d_tag) == elf.DT_NULL {
				break
			}
			if i64(entry.d_tag) == elf.DT_SONAME {
				soname = cstring_at(strings_bytes, int(entry.d_val))
			}
		}
	}
	if len(soname) > 0 {
		library.needed = strings.clone(soname, allocator) or_return
	} else if len(needed) > 0 {
		library.needed = strings.clone(needed, allocator) or_return
	} else {
		return {}, Malformed_File{detail = "shared object has no DT_SONAME and no library name"}
	}

	for section in sections {
		if u32(section.sh_type) != elf.SHT_DYNSYM {
			continue
		}
		if u64(section.sh_entsize) != size_of(elf.Symbol_Entry) || int(section.sh_link) >= section_count {
			return {}, Malformed_File{detail = "bad dynamic symbol table"}
		}
		bytes := section_bytes(data, section) or_return
		names := section_bytes(data, sections[section.sh_link]) or_return
		count := len(bytes) / size_of(elf.Symbol_Entry)
		for index in 0 ..< count {
			entry, entry_ok := read_pod(bytes, index * size_of(elf.Symbol_Entry), elf.Symbol_Entry)
			if !entry_ok {
				return {}, Malformed_File{detail = "truncated dynamic symbol"}
			}
			section_index := u16(entry.st_shndx)
			if section_index == u16(elf.SHN_UNDEF) || section_index >= u16(elf.SHN_LORESERVE) {
				continue
			}
			name := cstring_at(names, int(entry.st_name))
			if len(name) == 0 {
				continue
			}
			library.symbols[name] = true
		}
	}
	return library, nil
}

shared_library_destroy :: proc(library: ^Shared_Library) {
	if library == nil {
		return
	}
	delete(library.needed, library.allocator)
	delete(library.symbols)
	library^ = {}
}

package elf

import "core:bytes"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

// Fills a builder with the shape real compiler output has: progbits text
// and data sections, a NOBITS one, local, global, weak and undefined
// symbols, and PC32/PLT32/64 relocations against them.
make_full_builder :: proc() -> Builder {
	builder := builder_init()

	text := add_section(&builder, ".text", .SHT_PROGBITS, Section_Flags{.SHF_ALLOC, .SHF_EXECINSTR}, 16)
	section_add_data(&builder, text, []byte{0x55, 0x48, 0x89, 0xe5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00})
	data := add_section(&builder, ".data", .SHT_PROGBITS, Section_Flags{.SHF_WRITE, .SHF_ALLOC}, 8)
	section_add_data(&builder, data, []byte{0x01, 0x02, 0x03, 0x04})
	bss := add_section(&builder, ".bss", .SHT_NOBITS, Section_Flags{.SHF_WRITE, .SHF_ALLOC}, 8)
	section_reserve(&builder, bss, 16)

	// Unnamed section symbol, the canonical first local entry.
	add_symbol(&builder, "", .STB_LOCAL, .STT_SECTION, section_index(text), 0, 0)
	// Local object symbol in .data.
	add_symbol(&builder, "count", .STB_LOCAL, .STT_OBJECT, section_index(data), 0, 4)
	// Defined global function, referenced by a PLT32 call in .text.
	main_symbol := add_symbol(&builder, "main", .STB_GLOBAL, .STT_FUNC, section_index(text), 0, 8)
	// Weak, absolute value.
	add_symbol(&builder, "weak_abs", .STB_WEAK, .STT_NOTYPE, SHN_ABS, 0x4242, 0)
	// Undefined external, referenced by a PC32 in .text and a 64 in .data.
	undefined_symbol := add_symbol(&builder, "puts", .STB_GLOBAL, .STT_NOTYPE, SHN_UNDEF, 0, 0)

	add_reloc(&builder, text, undefined_symbol, .R_X86_64_PC32, 4, -4)
	add_reloc(&builder, text, main_symbol, .R_X86_64_PLT32, 8, -4)
	add_reloc(&builder, data, undefined_symbol, .R_X86_64_64, 0, 0)

	return builder
}

@(test)
write_object :: proc(t: ^testing.T) {
	empty := builder_init()
	defer builder_destroy(&empty)
	empty_object, empty_err := write(&empty)
	testing.expect(t, empty_err == nil, "write must succeed for an empty builder")
	defer delete(empty_object, context.allocator)

	empty_header := slice.reinterpret([]File_Header, empty_object)[0]
	testing.expect(t, bytes.equal(empty_header.ident[:4], []byte{0x7f, 'E', 'L', 'F'}), "ELF magic")
	testing.expect(t, empty_header.e_type == .ET_REL, "e_type")
	testing.expect(t, empty_header.e_machine == .EM_X86_64, "e_machine")
	testing.expect(t, u32(empty_header.e_version) == EV_CURRENT, "e_version")
	testing.expect(t, u32(empty_header.e_phnum) == 0, "no program headers")
	testing.expect(
		t,
		len(empty_object) == int(empty_header.e_shoff) + int(empty_header.e_shnum) * size_of(Section_Header),
		"file size is header table plus data",
	)
	testing.expect(t, u32(empty_header.e_shnum) == 4, "null section, symtab, strtab, shstrtab")
	testing.expect(t, u32(empty_header.e_shstrndx) == 3, "shstrtab last")

	#assert(size_of(Section_Header) == 64)
	empty_headers := slice.reinterpret([]Section_Header, empty_object[empty_header.e_shoff:])
	testing.expect(t, empty_headers[0].sh_type == .SHT_NULL, "null section")
	testing.expect(t, u64(empty_headers[0].sh_flags) == 0, "null section flags")
	testing.expect(t, u64(empty_headers[0].sh_offset) == 0, "null section offset")
	testing.expect(t, empty_headers[1].sh_type == .SHT_SYMTAB, "symtab")
	testing.expect(t, u32(empty_headers[1].sh_link) == 2, "symtab links to strtab")
	testing.expect(t, u32(empty_headers[1].sh_info) == 1, "first non-local symbol is entry 1")
	testing.expect(t, u64(empty_headers[1].sh_size) == size_of(Symbol_Entry), "only the null symbol")
	testing.expect(t, empty_headers[2].sh_type == .SHT_STRTAB, "strtab")
	testing.expect(t, u64(empty_headers[2].sh_size) == 1, "just the empty string")
	testing.expect(t, empty_headers[3].sh_type == .SHT_STRTAB, "shstrtab")
	testing.expect(t, u64(empty_headers[3].sh_size) > 1, "section names are present")

	builder := make_full_builder()
	defer builder_destroy(&builder)
	object, err := write(&builder)
	testing.expect(t, err == nil, "write must succeed")
	defer delete(object, context.allocator)

	header := slice.reinterpret([]File_Header, object)[0]
	// null, .text, .data, .bss, .symtab, .strtab, .rela.text, .rela.data, .shstrtab
	testing.expect(t, u32(header.e_shnum) == 9, "e_shnum")
	testing.expect(t, u32(header.e_shstrndx) == 8, "e_shstrndx")

	headers := slice.reinterpret([]Section_Header, object[header.e_shoff:])

	text_header := headers[1]
	testing.expect(t, text_header.sh_type == .SHT_PROGBITS, "text type")
	testing.expect(t, u64(text_header.sh_size) == 12, "text size")
	testing.expect(t, (u64(text_header.sh_flags) & 0x4) != 0, "text is executable")
	testing.expect(t, u64(text_header.sh_addralign) == 16, "text align")

	bss_header := headers[3]
	testing.expect(t, bss_header.sh_type == .SHT_NOBITS, "bss type")
	testing.expect(t, u64(bss_header.sh_size) == 16, "bss size")
	testing.expect(t, u64(bss_header.sh_offset) > 0, "NOBITS keeps an offset")

	symtab_header := headers[4]
	testing.expect(t, u32(symtab_header.sh_link) == 5, "symtab links to strtab")
	testing.expect(t, u32(symtab_header.sh_info) == 3, "two locals precede three non-locals")
	testing.expect(t, u64(symtab_header.sh_size) == 6 * size_of(Symbol_Entry), "symtab size")

	rela_text_header := headers[6]
	testing.expect(t, rela_text_header.sh_type == .SHT_RELA, "rela.text type")
	testing.expect(t, u32(rela_text_header.sh_link) == 4, "rela links to symtab")
	testing.expect(t, u32(rela_text_header.sh_info) == 1, "rela targets .text")
	testing.expect(t, (u64(rela_text_header.sh_flags) & 0x40) != 0, "rela carries SHF_INFO_LINK")
	testing.expect(t, u64(rela_text_header.sh_size) == 2 * size_of(Rela_Entry), "rela.text size")

	rela_data_header := headers[7]
	testing.expect(t, u32(rela_data_header.sh_link) == 4, "rela.data links to symtab")
	testing.expect(t, u32(rela_data_header.sh_info) == 2, "rela targets .data")
	testing.expect(t, u64(rela_data_header.sh_size) == size_of(Rela_Entry), "rela.data size")

	// Symbol table content: null symbol, locals in insertion order, then
	// global and weak symbols in insertion order.
	symbols := slice.reinterpret([]Symbol_Entry, object[u64(symtab_header.sh_offset):][:int(symtab_header.sh_size)])
	testing.expect(t, u32(symbols[0].st_name) == 0, "null symbol name")
	testing.expect(t, symbols[0].st_info == 0, "null symbol info")

	section_symbol := symbols[1]
	testing.expect(t, u32(section_symbol.st_name) == 0, "section symbols are unnamed")
	testing.expect(t, section_symbol.st_info == 3, "LOCAL SECTION")
	testing.expect(t, u16(section_symbol.st_shndx) == 1, "belongs to .text")

	count_symbol := symbols[2]
	testing.expect(t, count_symbol.st_info == 1, "LOCAL OBJECT")
	testing.expect(t, u16(count_symbol.st_shndx) == 2, "belongs to .data")
	testing.expect(t, u64(count_symbol.st_size) == 4, "count size")

	main_symbol := symbols[3]
	testing.expect(t, main_symbol.st_info == 1 << 4 | 2, "GLOBAL FUNC")
	testing.expect(t, u16(main_symbol.st_shndx) == 1, "belongs to .text")
	testing.expect(t, u64(main_symbol.st_value) == 0, "main value")

	weak_abs_symbol := symbols[4]
	testing.expect(t, weak_abs_symbol.st_info == 2 << 4 | 0, "WEAK NOTYPE")
	testing.expect(t, u16(weak_abs_symbol.st_shndx) == u16(SHN_ABS), "absolute")
	testing.expect(t, u64(weak_abs_symbol.st_value) == 0x4242, "weak value")

	undefined_symbol := symbols[5]
	testing.expect(t, undefined_symbol.st_info == 1 << 4 | 0, "GLOBAL NOTYPE")
	testing.expect(t, u16(undefined_symbol.st_shndx) == u16(SHN_UNDEF), "undefined")

	// Relocation content: symbol indices into the ordered symtab.
	entries := slice.reinterpret([]Rela_Entry, object[u64(rela_text_header.sh_offset):][:int(rela_text_header.sh_size)])
	pc32 := entries[0]
	testing.expect(t, u64(pc32.r_offset) == 4, "pc32 offset")
	testing.expect(t, u64(pc32.r_info) == u64(5) << 32 | 2, "PC32 against puts")
	testing.expect(t, i64(pc32.r_addend) == -4, "pc32 addend")

	plt32 := entries[1]
	testing.expect(t, u64(plt32.r_info) == u64(3) << 32 | 4, "PLT32 against main")

	data_entry := slice.reinterpret([]Rela_Entry, object[u64(rela_data_header.sh_offset):][:int(rela_data_header.sh_size)])[0]
	testing.expect(t, u64(data_entry.r_info) == u64(5) << 32 | 1, "word64 against puts in .data")

	// Dump both sample objects so they can be inspected with readelf and
	// objdump by hand.
	directory, directory_err := os.make_directory_temp("", "elf-write-*", context.temp_allocator)
	testing.expect(t, directory_err == nil, "temporary directory must be created")
	defer os.remove_all(directory)
	empty_path, _ := filepath.join({directory, "empty.o"}, context.temp_allocator)
	full_path, _ := filepath.join({directory, "full.o"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(empty_path, empty_object) == nil, "empty sample written")
	testing.expect(t, os.write_entire_file(full_path, object) == nil, "full sample written")
}

@(test)
write_is_deterministic :: proc(t: ^testing.T) {
	a := make_full_builder()
	defer builder_destroy(&a)
	object_a, err_a := write(&a)
	testing.expect(t, err_a == nil, "first write must succeed")
	defer delete(object_a, context.allocator)

	builder := make_full_builder()
	defer builder_destroy(&builder)
	object_b, err_b := write(&builder)
	testing.expect(t, err_b == nil, "second write must succeed")
	defer delete(object_b, context.allocator)

	testing.expect(t, len(object_a) > 0, "the object has content")
	testing.expect(t, bytes.equal(object_a, object_b), "two runs produce identical bytes")
}

@(test)
builder_misuse_errors :: proc(t: ^testing.T) {
	builder := builder_init()
	defer builder_destroy(&builder)

	err := section_add_data(&builder, Section_Handle(7), []byte{0})
	testing.expect(t, err == Error(.Unknown_Section), "unknown section in add_data")

	err = reserve_error(&builder, Section_Handle(7), 8)
	testing.expect(t, err == Error(.Unknown_Section), "unknown section in reserve")

	err = add_reloc(&builder, Section_Handle(7), Symbol_Handle(1), .R_X86_64_64, 0, 0)
	testing.expect(t, err == Error(.Unknown_Section), "unknown section in add_reloc")

	text := add_section(&builder, ".text", .SHT_PROGBITS, {}, 1)
	err = reserve_error(&builder, text, 8)
	testing.expect(t, err == Error(.Not_Nobits_Section), "reserve on progbits")

	err = add_reloc(&builder, text, Symbol_Handle(3), .R_X86_64_64, 0, 0)
	testing.expect(t, err == Error(.Unknown_Symbol), "unknown symbol")

	testing.expect(t, error_string(nil) == "None", "error_string of no error")
	testing.expect(t, error_string(Error(.Unknown_Symbol)) == "Unknown_Symbol", "error_string")
}

reserve_error :: proc(builder: ^Builder, target: Section_Handle, byte_count: int) -> Error {
	_, err := section_reserve(builder, target, byte_count)
	return err
}

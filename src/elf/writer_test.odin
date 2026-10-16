package elf

import "core:os"
import "core:slice"
import "core:testing"

@(test)
empty_object :: proc(t: ^testing.T) {
	b := builder_init()
	defer builder_destroy(&b)

	object, err := write(&b)
	testing.expect(t, err == nil, "write must succeed for an empty builder")
	testing.expect(t, len(object) == 64 + 3*64, "header plus three section headers")

	hdr := slice.reinterpret(File_Header, object)[0]
	testing.expect_value_eq(t, hdr.ident[:4], []byte{0x7f, 'E', 'L', 'F'})
	testing.expect_value_eq(t, hdr.e_type, .ET_REL)
	testing.expect_value_eq(t, hdr.e_machine, .EM_X86_64)
	testing.expect_value_eq(t, hdr.e_version, u32le(EV_CURRENT))
	testing.expect_value_eq(t, hdr.e_entry, u64le(0))
	testing.expect_value_eq(t, hdr.e_phoff, u64le(0))
	testing.expect_value_eq(t, hdr.e_ehsize, u16le(64))
	testing.expect_value_eq(t, hdr.e_shentsize, u16le(64))

	#assert(size_of(Section_Header) == 64)
	headers := slice.reinterpret(Section_Header, object[64:])
	testing.expect_value_eq(t, hdr.e_shnum, u16le(len(headers)))
	testing.expect_value_eq(t, hdr.e_shstrndx, u16le(len(headers)-1))

	null_sec := headers[0]
	testing.expect_value_eq(t, null_sec.sh_type, .SHT_NULL)
	testing.expect_value_eq(t, null_sec.sh_flags, u64le(0))
	testing.expect_value_eq(t, null_sec.sh_offset, u64le(0))

	symtab := headers[1]
	testing.expect_value_eq(t, symtab.sh_type, .SHT_SYMTAB)
	testing.expect_value_eq(t, symtab.sh_link, u32le(2), "symtab links to strtab")
	testing.expect_value_eq(t, symtab.sh_info, u32le(1), "first non-local symbol is entry 1")
	testing.expect_value_eq(t, symtab.sh_size, u64le(size_of(Symbol_Entry)))
	testing.expect_value_eq(t, symtab.sh_entsize, u64le(size_of(Symbol_Entry)))
	testing.expect_value_eq(t, symtab.sh_addralign, u64le(8))

	strtab := headers[2]
	testing.expect_value_eq(t, strtab.sh_type, .SHT_STRTAB)
	testing.expect_value_eq(t, strtab.sh_size, u64le(1))

	shstrtab := headers[3]
	testing.expect_value_eq(t, shstrtab.sh_type, .SHT_STRTAB)
	testing.expect_value_eq(t, shstrtab.sh_size > u64le(1), true, "section names are present")
}

// Fills a builder with the shape real compiler output has: progbits text
// and data sections, a NOBITS one, local, global, weak and undefined
// symbols, and PC32/PLT32/64 relocations against them.
make_full_builder :: proc() -> Builder {
	b := builder_init()

	text := add_section(&b, ".text", .SHT_PROGBITS, Section_Flags{.SHF_ALLOC, .SHF_EXECINSTR}, 16)
	section_add_data(&b, text, []byte{0x55, 0x48, 0x89, 0xe5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00})
	data := add_section(&b, ".data", .SHT_PROGBITS, Section_Flags{.SHF_WRITE, .SHF_ALLOC}, 8)
	section_add_data(&b, data, []byte{0x01, 0x02, 0x03, 0x04})
	bss := add_section(&b, ".bss", .SHT_NOBITS, Section_Flags{.SHF_WRITE, .SHF_ALLOC}, 8)
	section_reserve(&b, bss, 16)

	// Unnamed section symbol, the canonical first local entry.
	add_symbol(&b, "", .STB_LOCAL, .STT_SECTION, section_index(text), 0, 0)
	// Local object symbol in .data.
	add_symbol(&b, "count", .STB_LOCAL, .STT_OBJECT, section_index(data), 0, 4)
	// Defined global function, referenced by a PLT32 call in .text.
	main_sym := add_symbol(&b, "main", .STB_GLOBAL, .STT_FUNC, section_index(text), 0, 8)
	// Weak, absolute value.
	add_symbol(&b, "weak_abs", .STB_WEAK, .STT_NOTYPE, SHN_ABS, 0x4242, 0)
	// Undefined external, referenced by a PC32 in .text and a 64 in .data.
	undef_sym := add_symbol(&b, "puts", .STB_GLOBAL, .STT_NOTYPE, SHN_UNDEF, 0, 0)

	add_reloc(&b, text, undef_sym, .R_X86_64_PC32, 4, -4)
	add_reloc(&b, text, main_sym, .R_X86_64_PLT32, 8, -4)
	add_reloc(&b, data, undef_sym, .R_X86_64_64, 0, 0)

	return b
}

@(test)
full_object :: proc(t: ^testing.T) {
	b := make_full_builder()
	defer builder_destroy(&b)

	object, err := write(&b)
	testing.expect(t, err == nil, "write must succeed")

	hdr := slice.reinterpret(File_Header, object)[0]
	// null, .text, .data, .bss, .symtab, .strtab, .rela.text, .rela.data, .shstrtab
	testing.expect_value_eq(t, hdr.e_shnum, u16le(9))
	testing.expect_value_eq(t, hdr.e_shstrndx, u16le(8))

	headers := slice.reinterpret(Section_Header, object[64:])

	text_hdr := headers[1]
	testing.expect_value_eq(t, text_hdr.sh_type, .SHT_PROGBITS)
	testing.expect_value_eq(t, text_hdr.sh_size, u64le(12))
	testing.expect(t, (text_hdr.sh_flags & 0x4) != 0, "text is executable")
	testing.expect_value_eq(t, text_hdr.sh_addralign, u64le(16))

	bss_hdr := headers[3]
	testing.expect_value_eq(t, bss_hdr.sh_type, .SHT_NOBITS)
	testing.expect_value_eq(t, bss_hdr.sh_size, u64le(16))
	testing.expect(t, u32(bss_hdr.sh_offset) > 0, "NOBITS keeps an offset")

	symtab_hdr := headers[4]
	testing.expect_value_eq(t, symtab_hdr.sh_link, u32le(5))
	testing.expect_value_eq(t, symtab_hdr.sh_info, u32le(3), "two locals precede three non-locals")
	testing.expect_value_eq(t, symtab_hdr.sh_size, u64le(6*size_of(Symbol_Entry)))

	rela_text := headers[6]
	testing.expect_value_eq(t, rela_text.sh_type, .SHT_RELA)
	testing.expect_value_eq(t, rela_text.sh_link, u32le(4), "rela links to symtab")
	testing.expect_value_eq(t, rela_text.sh_info, u32le(1), "rela targets .text")
	testing.expect(t, (rela_text.sh_flags & 0x40) != 0, "rela carries SHF_INFO_LINK")
	testing.expect_value_eq(t, rela_text.sh_size, u64le(2*size_of(Rela_Entry)))

	rela_data := headers[7]
	testing.expect_value_eq(t, rela_data.sh_link, u32le(4))
	testing.expect_value_eq(t, rela_data.sh_info, u32le(2), "rela targets .data")
	testing.expect_value_eq(t, rela_data.sh_size, u64le(size_of(Rela_Entry)))

	// Symbol table content: null symbol, locals in insertion order, then
	// global and weak symbols in insertion order.
	symbols := slice.reinterpret(Symbol_Entry, object[u64(symtab_hdr.sh_offset):][:int(symtab_hdr.sh_size)])
	null_sym := symbols[0]
	testing.expect_value_eq(t, null_sym.st_name, u32le(0))
	testing.expect_value_eq(t, null_sym.st_info, u8(0))

	file_sym := symbols[1]
	testing.expect_value_eq(t, file_sym.st_name, u32le(0), "section symbols are unnamed")
	testing.expect_value_eq(t, file_sym.st_info, u8(3<<4 | 0), "LOCAL, SECTION")
	testing.expect_value_eq(t, file_sym.st_shndx, u16le(1))

	count_sym := symbols[2]
	testing.expect_value_eq(t, count_sym.st_info, u8(1<<4 | 1), "LOCAL, OBJECT")
	testing.expect_value_eq(t, count_sym.st_shndx, u16le(2))
	testing.expect_value_eq(t, count_sym.st_size, u64le(4))

	main_sym_out := symbols[3]
	testing.expect_value_eq(t, main_sym_out.st_info, u8(1<<4 | 2), "GLOBAL, FUNC")
	testing.expect_value_eq(t, main_sym_out.st_shndx, u16le(1))
	testing.expect_value_eq(t, main_sym_out.st_value, u64le(0))

	weak_sym := symbols[4]
	testing.expect_value_eq(t, weak_sym.st_info, u8(2<<4 | 0), "WEAK, NOTYPE")
	testing.expect_value_eq(t, weak_sym.st_shndx, u16le(SHN_ABS))
	testing.expect_value_eq(t, weak_sym.st_value, u64le(0x4242))

	undef_sym := symbols[5]
	testing.expect_value_eq(t, undef_sym.st_info, u8(1<<4 | 0), "GLOBAL, NOTYPE")
	testing.expect_value_eq(t, undef_sym.st_shndx, u16le(SHN_UNDEF))

	// Relocation content: symbol indices into the ordered symtab.
	entries := slice.reinterpret(Rela_Entry, object[u64(rela_text.sh_offset):][:int(rela_text.sh_size)])
	pc32 := entries[0]
	testing.expect_value_eq(t, pc32.r_offset, u64le(4))
	testing.expect_value_eq(t, pc32.r_info, u64(5)<<32 | 2, "PC32 against puts")
	testing.expect_value_eq(t, pc32.r_addend, i64le(-4))

	plt32 := entries[1]
	testing.expect_value_eq(t, plt32.r_info, u64(4)<<32 | 4, "PLT32 against main")

	entry := slice.reinterpret(Rela_Entry, object[u64(rela_data.sh_offset):][:int(rela_data.sh_size)])[0]
	testing.expect_value_eq(t, entry.r_info, u64(5)<<32 | 1, "word64 against puts in .data")
}

@(test)
write_is_deterministic :: proc(t: ^testing.T) {
	a := make_full_builder()
	defer builder_destroy(&a)
	object_a, err_a := write(&a)
	testing.expect(t, err_a == nil, "first write must succeed")

	b := make_full_builder()
	defer builder_destroy(&b)
	object_b, err_b := write(&b)
	testing.expect(t, err_b == nil, "second write must succeed")

	testing.expect_value_eq(t, object_a, object_b, "two runs produce identical bytes")
}

@(test)
builder_misuse_errors :: proc(t: ^testing.T) {
	b := builder_init()
	defer builder_destroy(&b)

	_, err := section_add_data(&b, Section_Handle(7), []byte{0})
	testing.expect_value_eq(t, err, Error(.Unknown_Section))

	_, err = section_reserve(&b, Section_Handle(7), 8)
	testing.expect_value_eq(t, err, Error(.Unknown_Section))

	err = add_reloc(&b, Section_Handle(7), Symbol_Handle(1), .R_X86_64_64, 0, 0)
	testing.expect_value_eq(t, err, Error(.Unknown_Section))

	text := add_section(&b, ".text", .SHT_PROGBITS, {}, 1)
	_, err = section_reserve(&b, text, 8)
	testing.expect_value_eq(t, err, Error(.Not_Nobits_Section))

	err = add_reloc(&b, text, Symbol_Handle(3), .R_X86_64_64, 0, 0)
	testing.expect_value_eq(t, err, Error(.Unknown_Symbol))

	err = error_message(t, Error(.None))
	testing.expect_value_eq(t, err, Error(.None))
}

@(private)
error_message :: proc(t: ^testing.T, err: Error) -> Error {
	testing.expect(t, error_string(err) == "None", "error_string renders None")
	testing.expect(t, error_string(Error(.Unknown_Symbol)) == "Unknown_Symbol")
	return err
}

// Emits the built objects so they can be inspected with readelf and
// objdump by hand.  Not a real assertion; failure is reported, not fatal.
@(test)
write_sample_objects :: proc(t: ^testing.T) {
	b := builder_init()
	defer builder_destroy(&b)
	object, err := write(&b)
	testing.expect(t, err == nil, "empty write must succeed")
	testing.expect(t, os.write_entire_file("/tmp/opencode/elf-empty.o", object))

	b = make_full_builder()
	defer builder_destroy(&b)
	object, err = write(&b)
	testing.expect(t, err == nil, "full write must succeed")
	testing.expect(t, os.write_entire_file("/tmp/opencode/elf-full.o", object))
}

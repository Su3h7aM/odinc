package elf

/*
	Mirror types and constants of the ELF64 file format.

	Structs match the ELF64 spec layout one to one and are `#packed`, using
	the little-endian integer types.  Enumerations and constants carry the
	names used by the specification: `SHT_NULL`, `SHF_WRITE`, `STB_LOCAL`, ...

	Writing of section contents resolves relocations per the ELF spec.
	Executable output (`ET_EXEC`) is out of scope.
*/

ELF_MAGIC :: "\x7fELF"

// Byte offsets into `e_ident` (ELF spec, "Elf64_Ident").
EI_MAG0 :: 0
EI_CLASS :: 4
EI_DATA :: 5
EI_VERSION :: 6
EI_OSABI :: 7
EI_ABIVERSION :: 8
EI_NIDENT :: 16

ELFCLASS64 :: 2 // e_ident[EI_CLASS]: 64 bit object, the only class we write
ELFDATA2LSB :: 1 // e_ident[EI_DATA]: two's complement, little endian
EV_CURRENT :: 1 // file format version

// `e_type`, the object file type.
ET :: enum u16le {
	ET_NONE = 0, // no file type
	ET_REL  = 1, // relocatable file
	ET_EXEC = 2, // executable file (not written by this package)
	ET_DYN  = 3, // shared object file
	ET_CORE = 4, // core file
}

// `e_machine`, target architectures (subset needed by this package).
EM :: enum u16le {
	EM_NONE   = 0,
	EM_X86_64 = 62, // AMD x86-64 architecture
}

// `sh_type`, section types (subset needed by this package).
SHT :: enum u32le {
	SHT_NULL     = 0, // inactive/null section header
	SHT_PROGBITS = 1, // program-defined information
	SHT_SYMTAB   = 2, // symbol table
	SHT_STRTAB   = 3, // string table
	SHT_RELA     = 4, // relocation entries with addends
	SHT_NOBITS   = 8, // occupies no space in the file
}

// Bit positions of the `sh_flags` section attributes.
SHF :: enum u8 {
	SHF_WRITE            = 0, // 0x1: writable during process execution
	SHF_ALLOC            = 1, // 0x2: occupies memory during process execution
	SHF_EXECINSTR        = 2, // 0x4: executable machine instructions
	SHF_MERGE            = 4, // 0x10: might be merged to eliminate duplication
	SHF_STRINGS          = 5, // 0x20: contains nul-terminated strings
	SHF_INFO_LINK        = 6, // 0x40: sh_info holds a section header index
	SHF_LINK_ORDER       = 7, // 0x80: special ordering requirements
	SHF_OS_NONCONFORMING = 8, // 0x100: OS-specific processing required
	SHF_GROUP            = 9, // 0x200: member of a section group
	SHF_TLS              = 10, // 0x400: thread-local storage
	SHF_COMPRESSED       = 11, // 0x800: holds compressed data
	SHF_EXCLUDE          = 31, // 0x80000000: excluded unless referenced
}

Section_Flags :: bit_set[SHF;u64]

// `st_shndx` special section index values.
SHN_UNDEF :: Section_Index(0) // undefined symbol
SHN_LORESERVE :: 0xff00 // reserved index range, low bound
SHN_ABS :: Section_Index(0xfff1) // absolute value, not affected by relocation
SHN_HIRESERVE :: 0xffff // reserved index range, high bound

// `st_info` bits 0-3: symbol binding.
STB :: enum u8 {
	STB_LOCAL  = 0, // not visible outside its object file
	STB_GLOBAL = 1, // visible to all object files being combined
	STB_WEAK   = 2, // lower precedence global binding
}

// `st_info` bits 4-7: symbol type.
STT :: enum u8 {
	STT_NOTYPE  = 0, // no type specified
	STT_OBJECT  = 1, // data object
	STT_FUNC    = 2, // function
	STT_SECTION = 3, // associated with a section, no name
	STT_FILE    = 4, // file, section index SHN_ABS
}

// `r_info`[0..31]: x86-64 relocation types (numerical values per the ELF
// x86-64 psABI); `r_info` packs them as (symbol index << 32) | r_type.
R_X86_64 :: enum u32le {
	R_X86_64_NONE     = 0, // no relocation
	R_X86_64_64       = 1, // S + A, word64
	R_X86_64_PC32     = 2, // S + A - P, word32
	R_X86_64_GOT32    = 3, // G + A, word32
	R_X86_64_PLT32    = 4, // L + A - P, word32
	R_X86_64_GOTPCREL = 9, // G + GOT + A - P, word32
	R_X86_64_32       = 10, // S + A truncated to u32
	R_X86_64_32S      = 11, // S + A sign-extended to i64 as i32
	R_X86_64_TPOFF32  = 23, // TLS offset
}

/*
	ELF64 file header (spec type Elf64_Ehdr), 64 bytes.
*/
File_Header :: struct #packed {
	ident:       [EI_NIDENT]u8,
	e_type:      ET,
	e_machine:   EM,
	e_version:   u32le,
	e_entry:     u64le,
	e_phoff:     u64le,
	e_shoff:     u64le,
	e_flags:     u32le,
	e_ehsize:    u16le,
	e_phentsize: u16le,
	e_phnum:     u16le,
	e_shentsize: u16le,
	e_shnum:     u16le,
	e_shstrndx:  u16le,
}

/*
	ELF64 section header (spec type Elf64_Shdr), 64 bytes.
	`sh_flags` is stored in its spec integer form; use `section_flags_mask`
	to turn a `Section_Flags` set into that form and `flags_from_section_mask`
	to turn it back.
*/
Section_Header :: struct #packed {
	sh_name:      u32le,
	sh_type:      SHT,
	sh_flags:     u64le,
	sh_addr:      u64le,
	sh_offset:    u64le,
	sh_size:      u64le,
	sh_link:      u32le,
	sh_info:      u32le,
	sh_addralign: u64le,
	sh_entsize:   u64le,
}

/*
	ELF64 symbol table entry (spec type Elf64_Sym), 24 bytes.
	`st_info` packs binding in the upper nibble and type in the lower nibble.
*/
Symbol_Entry :: struct #packed {
	st_name:  u32le,
	st_info:  u8,
	st_other: u8,
	st_shndx: u16le,
	st_value: u64le,
	st_size:  u64le,
}

/*
	ELF64 relocation entry with addend (spec type Elf64_Rela), 24 bytes.
	`r_info` packs the symbol index in the upper 32 bits and the relocation
	type in the lower 32 bits.
*/
Rela_Entry :: struct #packed {
	r_offset: u64le,
	r_info:   u64le,
	r_addend: i64le,
}

/*
	Returns the spec's integer form of a section flag set (the value that is
	stored in `sh_flags`).
*/
section_flags_mask :: proc(flags: Section_Flags) -> u64 {
	return transmute(u64)(flags)
}

/*
	Returns the flag set stored in a `sh_flags` integer.
*/
flags_from_section_mask :: proc(mask: u64) -> Section_Flags {
	return transmute(Section_Flags)(mask)
}

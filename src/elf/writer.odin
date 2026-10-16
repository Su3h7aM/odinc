package elf

import "base:runtime"
import "core:mem"
import "core:slice"

/*
	Handle to a section inside one `Builder`.  Zero never names a section.
*/
Section_Handle :: distinct u32

/*
	Handle to a symbol inside one `Builder`.  Zero never names a symbol.
*/
Symbol_Handle :: distinct u32

/*
	A section table index as it appears in `st_shndx`.  Use one of the
	spec's reserved values when no section applies: see `SHN_UNDEF` and
	`SHN_ABS`.
*/
Section_Index :: distinct u16

/*
	Error values returned by the writer.  `Writer_Error` covers builder
	misuse, `runtime.Allocator_Error` covers allocation failure.
*/
Error :: union #shared_nil {
	Writer_Error,
	runtime.Allocator_Error,
}

/*
	Builder misuse errors.  Starts at `None` so a zero value means success.
*/
Writer_Error :: enum {
	None,
	Unknown_Section,
	Unknown_Symbol,
	Invalid_Segment,
	Not_Nobits_Section,
	Too_Many_Sections,
}

/*
	Returns the name of an `Error` variant, `"None"` when there is no
	error.
*/
error_string :: proc(err: Error) -> string {
	if err == nil {
		return "None"
	}
	switch e in err {
	case Writer_Error:
		switch e {
		case .None:
			return "None"
		case .Unknown_Section:
			return "Unknown_Section"
		case .Unknown_Symbol:
			return "Unknown_Symbol"
		case .Invalid_Segment:
			return "Invalid_Segment"
		case .Not_Nobits_Section:
			return "Not_Nobits_Section"
		case .Too_Many_Sections:
			return "Too_Many_Sections"
		}
	case runtime.Allocator_Error:
		switch e {
		case .None:
			return "None"
		case .Out_Of_Memory:
			return "Out_Of_Memory"
		case .Invalid_Pointer:
			return "Invalid_Pointer"
		case .Invalid_Argument:
			return "Invalid_Argument"
		case .Mode_Not_Implemented:
			return "Mode_Not_Implemented"
		}
	}
	return "Unknown"
}

/*
	One section recorded by the builder.

	`data` holds the section's bytes.  For `SHT_NOBITS` sections those
	bytes are not written into the object file, but their size still takes
	part in the layout; use `section_reserve` to size such a section and
	get a view through which its content can be written.
*/
Section :: struct {
	name:         string,
	sh_type:      SHT,
	flags:        Section_Flags,
	sh_addralign: u64,
	sh_entsize:   u64,
	data:         [dynamic]u8,
	relocations:  [dynamic]Relocation,
}

/*
	One relocation request, emitted into `.rela.<target section>`.
	`offset` is the apply address relative to the target section's
	start; `addend` becomes `r_addend`.
*/
Relocation :: struct {
	symbol: Symbol_Handle,
	kind:   R_X86_64,
	offset: u64,
	addend: i64,
}

/*
	One symbol recorded by the builder.  `shndx` is a real section table
	index (see `section_index`) or one of the spec's reserved values
	(`SHN_UNDEF` for an undefined symbol, `SHN_ABS` for an absolute value).
*/
Symbol :: struct {
	name:     string,
	binding:  STB,
	kind:     STT,
	shndx:    Section_Index,
	st_value: u64,
	st_size:  u64,
}

/*
	Accumulates sections, symbols, and relocations until `write`
	serializes them.  Nothing is allocated until content is added.
*/
Builder :: struct {
	allocator: mem.Allocator,
	sections:  [dynamic]^Section,
	symbols:   [dynamic]Symbol,
}

/*
	Returns a zero-content `Builder` that allocates with `allocator`
	(defaults to `context.allocator`).
*/
builder_init :: proc(allocator := context.allocator) -> Builder {
	return Builder{allocator = allocator}
}

/*
	Frees everything the builder owns.  Afterwards the builder must not be
	used again.
*/
builder_destroy :: proc(builder: ^Builder) {
	for section in builder.sections {
		free_dynamic(section.data)
		free_dynamic(section.relocations)
		free_string(section.name, builder.allocator)
		mem.free(section, builder.allocator)
	}
	free_dynamic(builder.sections)
	for symbol in builder.symbols {
		free_string(symbol.name, builder.allocator)
	}
	free_dynamic(builder.symbols)
}

/*
	Adds a section.  The name is cloned into the builder; returns a handle
	whose zero value is never used.

	`sh_addralign` may be zero: the spec treats `0 or 1` as unconstrained,
	and the writer applies it as given.  It should be a power of two
	otherwise.
*/
add_section :: proc(builder: ^Builder, name: string, sh_type: SHT, flags: Section_Flags, sh_addralign: u64) -> Section_Handle {
	section, alloc_err := mem.new(Section, builder.allocator)
	if alloc_err != nil {
		return 0
	}

	section.name = clone_string(name, builder.allocator)
	section.sh_type = sh_type
	section.flags = flags
	section.sh_addralign = sh_addralign
	section.data = make([dynamic]u8, 0, builder.allocator)
	section.relocations = make([dynamic]Relocation, 0, builder.allocator)

	if builder.sections == nil {
		builder.sections = make([dynamic]^Section, 0, builder.allocator)
	}
	append(&builder.sections, section)
	return Section_Handle(u32(len(builder.sections)))
}

/*
	Appends a copy of `data` to a section's content.  The builder owns the
	copy; the caller keeps ownership of `data`.
*/
section_add_data :: proc(builder: ^Builder, target: Section_Handle, data: []byte) -> Error {
	section := get_section(builder, target)
	if section == nil {
		return .Unknown_Section
	}
	if len(data) == 0 {
		return nil
	}

	append(&section.data, ..data)
	return nil
}

/*
	Sizes a `SHT_NOBITS` section to exactly `byte_count` zeroed bytes and
	returns a view through which the caller can write its content.  Other
	section types get `Not_Nobits_Section`.
*/
section_reserve :: proc(builder: ^Builder, target: Section_Handle, byte_count: int) -> ([]byte, Error) {
	section := get_section(builder, target)
	if section == nil {
		return nil, .Unknown_Section
	}
	if section.sh_type != .SHT_NOBITS || byte_count < 0 {
		return nil, .Not_Nobits_Section
	}

	free_dynamic(section.data)
	section.data = make([dynamic]u8, byte_count, builder.allocator)
	return section.data[:], nil
}

/*
	Returns the section table index a symbol's `shndx` should carry for
	this section.  No validation of the handle itself.
*/
section_index :: proc(target: Section_Handle) -> Section_Index {
	return Section_Index(u16(u32(target)))
}

/*
	Adds a symbol whose name is cloned into the builder.  An empty name is
	allowed (ELF has unnamed symbols, e.g. `STT_SECTION` entries).
*/
add_symbol :: proc(builder: ^Builder, name: string, binding: STB, kind: STT, shndx: Section_Index, st_value: u64, st_size: u64) -> Symbol_Handle {
	symbol := Symbol {
		name     = clone_string(name, builder.allocator),
		binding  = binding,
		kind     = kind,
		shndx    = shndx,
		st_value = st_value,
		st_size  = st_size,
	}

	if builder.symbols == nil {
		builder.symbols = make([dynamic]Symbol, 0, builder.allocator)
	}
	append(&builder.symbols, symbol)
	return Symbol_Handle(u32(len(builder.symbols)))
}

/*
	Requests a relocation with apply address `offset` bytes into the
	target section, referencing `symbol`, with `addend` as the ELF `A`.
*/
add_reloc :: proc(builder: ^Builder, target: Section_Handle, symbol: Symbol_Handle, kind: R_X86_64, offset: u64, addend: i64) -> Error {
	target_section := get_section(builder, target)
	if target_section == nil {
		return .Unknown_Section
	}
	if get_symbol(builder, symbol) == nil {
		return .Unknown_Symbol
	}

	append(&target_section.relocations, Relocation{symbol = symbol, kind = kind, offset = offset, addend = addend})
	return nil
}

/*
	Serializes the builder into the bytes of a complete ELF64 relocatable
	object.  The emitted sections are, in order, the builder's own, then
	`.symtab` (locals before global and weak symbols), `.strtab`, one
	`.rela.<name>` per section that carries relocations, and `.shstrtab`
	last; every `sh_link`/`sh_info` pair is set accordingly.

	`object` is exactly one allocation; the caller owns it and must
	`delete` it with the allocator given here.
*/
write :: proc(builder: ^Builder, allocator := context.allocator) -> (object: []u8, err: Error) {
	shstrtab: String_Table
	strtab: String_Table
	string_table_init(&shstrtab, allocator)
	string_table_init(&strtab, allocator)
	defer string_table_destroy(&shstrtab, allocator)
	defer string_table_destroy(&strtab, allocator)

	relocation_section_names: [dynamic]string
	relocation_section_names = make([dynamic]string, 0, allocator)
	defer {
		for name in relocation_section_names {
			free_string(name, allocator)
		}
		free_dynamic(relocation_section_names)
	}

	local_symbol_count := 0
	for symbol in builder.symbols {
		if symbol.binding == .STB_LOCAL {
			local_symbol_count += 1
		}
	}

	// Symtab order: null symbol, then locals, then global and weak
	// symbols, all in insertion order; `sh_info` is the index of the
	// first non-local symbol.
	symtab_positions := make([dynamic]u32, len(builder.symbols), allocator)
	defer free_dynamic(symtab_positions)

	next_local_index := 1
	next_global_index := 1 + local_symbol_count
	for symbol, symbol_position in builder.symbols {
		if symbol.binding == .STB_LOCAL {
			symtab_positions[symbol_position] = u32(next_local_index)
			next_local_index += 1
		} else {
			symtab_positions[symbol_position] = u32(next_global_index)
			next_global_index += 1
		}
		string_table_intern(&strtab, symbol.name)
	}

	symtab_index := len(builder.sections) + 1
	strtab_index := len(builder.sections) + 2

	section_headers := make([dynamic]Section_Header, 0, allocator)
	defer free_dynamic(section_headers)

	// Index 0 is the spec's null section header.
	append(&section_headers, Section_Header{})

	for section in builder.sections {
		append(
			&section_headers,
			Section_Header {
				sh_name = u32le(u32(string_table_intern(&shstrtab, section.name))),
				sh_type = section.sh_type,
				sh_flags = u64le(section_flags_mask(section.flags)),
				sh_size = u64le(u64(len(section.data))),
				sh_addralign = u64le(section.sh_addralign),
				sh_entsize = u64le(section.sh_entsize),
			},
		)
	}

	append(
		&section_headers,
		Section_Header {
			sh_type = .SHT_SYMTAB,
			sh_link = u32le(u32(strtab_index)),
			sh_info = u32le(u32(1 + local_symbol_count)),
			sh_size = u64le(u64(SYMBOL_ENTRY_SIZE * (len(builder.symbols) + 1))),
			sh_addralign = u64le(8),
			sh_entsize = u64le(SYMBOL_ENTRY_SIZE),
		},
	)

	append(&section_headers, Section_Header{sh_type = .SHT_STRTAB, sh_size = u64le(u64(len(strtab.storage))), sh_addralign = u64le(1)})

	section_headers[symtab_index].sh_name = u32le(u32(string_table_intern(&shstrtab, ".symtab")))
	section_headers[strtab_index].sh_name = u32le(u32(string_table_intern(&shstrtab, ".strtab")))

	// One `.rela.<name>` per section that carries relocations, in section
	// order, so resolver runs walk the table front to back.
	for section, section_position in builder.sections {
		if len(section.relocations) == 0 {
			continue
		}
		relocation_section_name := concat_string(".rela", section.name, allocator)
		append(&relocation_section_names, relocation_section_name)
		append(
			&section_headers,
			Section_Header {
				sh_name = u32le(u32(string_table_intern(&shstrtab, relocation_section_name))),
				sh_type = .SHT_RELA,
				sh_flags = u64le(section_flags_mask(Section_Flags{.SHF_INFO_LINK})),
				sh_link = u32le(u32(symtab_index)),
				sh_info = u32le(u32(section_position + 1)),
				sh_size = u64le(u64(RELA_ENTRY_SIZE * len(section.relocations))),
				sh_addralign = u64le(8),
				sh_entsize = u64le(RELA_ENTRY_SIZE),
			},
		)
	}

	shstrtab_index := len(section_headers)
	append(
		&section_headers,
		Section_Header {
			sh_name = u32le(u32(string_table_intern(&shstrtab, ".shstrtab"))),
			sh_type = .SHT_STRTAB,
			sh_size = u64le(u64(len(shstrtab.storage))),
			sh_addralign = u64le(1),
		},
	)

	if len(section_headers) > 0xffff {
		return nil, Error(.Too_Many_Sections)
	}

	// Section data in emission order, then the section header table.
	// `SHT_NOBITS` keeps `sh_offset` but occupies no bytes in the file.
	cursor: u64 = FILE_HEADER_SIZE
	for index in 1 ..< len(section_headers) {
		section_header := &section_headers[index]
		sh_offset := align_up(cursor, u64(section_header.sh_addralign))
		section_header.sh_offset = u64le(sh_offset)
		if section_header.sh_type != .SHT_NOBITS {
			cursor = sh_offset + u64(section_header.sh_size)
		}
	}
	section_table_offset := align_up(cursor, 8)
	total_size := section_table_offset + u64(SECTION_HEADER_SIZE * len(section_headers))

	data, alloc_err := mem.alloc_bytes(int(total_size), allocator = allocator)
	if alloc_err != nil {
		return nil, Error(alloc_err)
	}
	object = data

	for section, section_position in builder.sections {
		if section.sh_type == .SHT_NOBITS || len(section.data) == 0 {
			continue
		}
		copy(object[u64(section_headers[section_position + 1].sh_offset):], section.data[:])
	}

	copy(object[u64(section_headers[strtab_index].sh_offset):], strtab.storage[:])
	copy(object[u64(section_headers[shstrtab_index].sh_offset):], shstrtab.storage[:])

	// Entries in the order the names were interned: the null symbol,
	// then locals, then global and weak symbols.
	symtab_position := u64(section_headers[symtab_index].sh_offset)
	blit(object, int(symtab_position), Symbol_Entry{})
	next := int(symtab_position) + SYMBOL_ENTRY_SIZE
	for pass := 0; pass < 2; pass += 1 {
		for symbol in builder.symbols {
			if (symbol.binding == .STB_LOCAL) == (pass == 0) {
				blit(
					object,
					next,
					Symbol_Entry {
						st_name = u32le(u32(string_table_intern(&strtab, symbol.name))),
						st_info = u8(symbol.binding) << 4 | u8(symbol.kind),
						st_shndx = u16le(u16(symbol.shndx)),
						st_value = u64le(symbol.st_value),
						st_size = u64le(symbol.st_size),
					},
				)
				next += SYMBOL_ENTRY_SIZE
			}
		}
	}

	// Relocation entries against their positions in `.symtab`.
	relocation_header_index := symtab_index + 2
	for section in builder.sections {
		if len(section.relocations) == 0 {
			continue
		}
		next = int(u64(section_headers[relocation_header_index].sh_offset))
		for relocation in section.relocations {
			symbol_position := symtab_positions[u32(relocation.symbol) - 1]
			blit(
				object,
				next,
				Rela_Entry {
					r_offset = u64le(relocation.offset),
					r_info = u64le(u64(symbol_position) << 32 | u64(transmute(u32)(relocation.kind))),
					r_addend = i64le(relocation.addend),
				},
			)
			next += RELA_ENTRY_SIZE
		}
		relocation_header_index += 1
	}

	header_position := section_table_offset
	for section_header in section_headers {
		blit(object, int(header_position), section_header)
		header_position += SECTION_HEADER_SIZE
	}

	blit(
		object,
		0,
		File_Header {
			ident = IDENTITY,
			e_type = .ET_REL,
			e_machine = .EM_X86_64,
			e_version = u32le(EV_CURRENT),
			e_entry = u64le(0),
			e_phoff = u64le(0),
			e_shoff = u64le(section_table_offset),
			e_ehsize = u16le(FILE_HEADER_SIZE),
			e_shentsize = u16le(SECTION_HEADER_SIZE),
			e_shnum = u16le(len(section_headers)),
			e_shstrndx = u16le(shstrtab_index),
		},
	)

	return object, nil
}

// ---------------------------------------------------------------- //
// Internals
// ---------------------------------------------------------------- //

FILE_HEADER_SIZE :: size_of(File_Header) // 64
SECTION_HEADER_SIZE :: size_of(Section_Header) // 64
SYMBOL_ENTRY_SIZE :: size_of(Symbol_Entry) // 24
RELA_ENTRY_SIZE :: size_of(Rela_Entry) // 24

IDENTITY :: [EI_NIDENT]u8{0x7f, 'E', 'L', 'F', ELFCLASS64, ELFDATA2LSB, EV_CURRENT, 0, 0, 0, 0, 0, 0, 0, 0, 0}

clone_string :: proc(s: string, allocator: mem.Allocator) -> string {
	if len(s) == 0 {
		return ""
	}
	buffer, alloc_err := mem.alloc_bytes(len(s), allocator = allocator)
	if alloc_err != nil {
		return ""
	}
	copy(buffer, s)
	return string(buffer)
}

free_string :: proc(s: string, allocator: mem.Allocator) {
	if len(s) > 0 {
		mem.free(raw_data(s), allocator)
	}
}

concat_string :: proc(a, b: string, allocator: mem.Allocator) -> string {
	buffer, alloc_err := mem.alloc_bytes(len(a) + len(b), allocator = allocator)
	if alloc_err != nil {
		return ""
	}
	copy(buffer[:len(a)], a)
	copy(buffer[len(a):], b)
	return string(buffer)
}

String_Table_Entry :: struct {
	// Offset of the string's first character inside the table.
	offset: u64,
	// Borrowed view of the interned name; lives as long as the table.
	name:   string,
}

/*
	An ELF-style string table: a byte blob of nul-terminated strings where
	offset 0 is always the empty string.  Interning is a linear scan over
	the entry list in insertion order, so layout stays deterministic.
*/
String_Table :: struct {
	storage: [dynamic]u8,
	entries: [dynamic]String_Table_Entry,
}

string_table_init :: proc(table: ^String_Table, allocator: mem.Allocator) {
	table.storage = make([dynamic]u8, 1, allocator)
	table.entries = make([dynamic]String_Table_Entry, 0, allocator)
	append(&table.entries, String_Table_Entry{offset = 0, name = ""})
}

string_table_destroy :: proc(table: ^String_Table, allocator: mem.Allocator) {
	free_dynamic(table.storage)
	free_dynamic(table.entries)
}

string_table_intern :: proc(table: ^String_Table, entry_name: string) -> u64 {
	if len(entry_name) == 0 {
		return 0
	}
	for entry in table.entries {
		if entry.name == entry_name {
			return entry.offset
		}
	}
	offset := u64(len(table.storage))
	append(&table.storage, entry_name)
	append(&table.storage, u8(0))
	append(&table.entries, String_Table_Entry{offset = offset, name = entry_name})
	return offset
}

// Writes the bytes of `src` into `dst` at `pos`.
blit :: proc "contextless" (dst: []byte, pos: int, src: $T) {
	one: [1]T = {src}
	copy(dst[pos:], slice.to_bytes(one[:]))
}

// Rounds `pos` up to a multiple of `alignment`; values of `1 or 0` are unconstrained.
align_up :: proc "contextless" (pos: u64, alignment: u64) -> u64 {
	if alignment <= 1 {
		return pos
	}
	return (pos + alignment - 1) &~ (alignment - 1)
}

// A no-op for empty arrays, so a zero struct deletes cleanly.
free_dynamic :: proc(array: [dynamic]$T) {
	if len(array) > 0 {
		delete(array)
	}
}

get_section :: proc "contextless" (builder: ^Builder, handle: Section_Handle) -> ^Section {
	handle_index := u32(handle)
	if handle_index == 0 || int(handle_index) > len(builder.sections) {
		return nil
	}
	return builder.sections[int(handle_index) - 1]
}

get_symbol :: proc "contextless" (builder: ^Builder, handle: Symbol_Handle) -> ^Symbol {
	handle_index := u32(handle)
	if handle_index == 0 || int(handle_index) > len(builder.symbols) {
		return nil
	}
	return &builder.symbols[int(handle_index) - 1]
}

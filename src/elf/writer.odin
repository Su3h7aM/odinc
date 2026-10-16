package elf

/*
	Collects sections, symbols, and relocations and serializes them into
	ELF64 little-endian x86-64 relocatable objects (.o).

	`write` emits everything an object file needs: the `.symtab`,
	`.strtab`, `.shstrtab`, one `.rela.<name>` section per section that
	carries relocations, plus the builder's own sections.  Locals are
	emitted into `.symtab` before global and weak symbols;
	`sh_link`/`sh_info` pairs map `.symtab` to `.strtab`, and each
	`.rela.<section>` to `.symtab` and to its target section.

	See `doc.odin` for the memory and determinism contract.
*/

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
	A section table index as it appears in `st_shndx` of a symbol.
	Use one of the spec's reserved values when no section applies: see
	`SHN_UNDEF` and `SHN_ABS`.
*/
Section_Index :: distinct u16

/*
	Error values returned by the builder and `write`.
	`Writer_Error` covers builder misuse; `runtime.Allocator_Error` covers
	allocation failure.
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
	Not_Nobits_Section,
	Too_Many_Sections,
}

/*
	Returns the name of an `Error` variant, `"None"` when there is no
	error.  Never allocates.
*/
error_string :: proc(err: Error) -> string {
	switch e in err {
	case Writer_Error:
		switch e {
		case .None:
			return "None"
		case .Unknown_Section:
			return "Unknown_Section"
		case .Unknown_Symbol:
			return "Unknown_Symbol"
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
	One section as recorded by the `Builder`.

	`data` holds the section's bytes.  For `SHT_NOBITS` sections those
	bytes are not written into the object file, but their size still takes
	part in the layout; use `section_reserve` to size the section and to
	get a view through which its content can be written.
*/
Section :: struct {
	name:      string,
	sh_type:   SHT,
	flags:     Section_Flags,
	addralign: u64,
	entsize:   u64,
	data:      [dynamic]u8,
	relos:     [dynamic]Relocation,
}

/*
	One relocation request, emitted into `.rela.<target section>`.
	`offset` is the apply address relative to the target section's start;
	`addend` becomes `r_addend`.
*/
Relocation :: struct {
	symbol: Symbol_Handle,
	kind:   R_X86_64,
	offset: u64,
	addend: i64,
}

/*
	One symbol as recorded by the `Builder`.
	`shndx` is a real section table index (see `section_index`) or one of
	the spec's reserved values (`SHN_UNDEF` for an undefined symbol,
	`SHN_ABS` for an absolute value).
*/
Symbol :: struct {
	name:    string,
	binding: STB,
	kind:    STT,
	shndx:   Section_Index,
	value:   u64,
	size:    u64,
}

/*
	Accumulates sections, symbols, and relocations until `write`
	serializes them.

	Initialize with `builder_init` and release with `builder_destroy`.
	Nothing is allocated until content is added.
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
	Frees everything the builder owns: sections, their data and
	relocations, symbol records, and cloned names.  Destroying a zero
	struct is a no-op; afterwards the builder must not be used again.
*/
builder_destroy :: proc(b: ^Builder) {
	for sec in b.sections {
		free_dynamic(sec.data)
		free_dynamic(sec.relos)
		free_string(sec.name, b.allocator)
		mem.free(sec, b.allocator)
	}
	free_dynamic(b.sections)
	for sym in b.symbols {
		free_string(sym.name, b.allocator)
	}
	free_dynamic(b.symbols)
}

/*
	Adds a section.  The name is cloned into the builder.

	`addralign` may be zero: the spec treats `sh_addralign == 0 or 1` as
	unconstrained, and the writer applies it as given.  It should be a
	power of two otherwise.

	Returns a handle to the new section.  The zero value is never
	returned.
*/
add_section :: proc(b: ^Builder, name: string, sh_type: SHT, flags: Section_Flags, addralign: u64) -> Section_Handle {
	sec, alloc_err := mem.new(Section, b.allocator)
	if alloc_err != nil {
		return 0
	}

	sec.name = clone_string(name, b.allocator)
	sec.sh_type = sh_type
	sec.flags = flags
	sec.addralign = addralign
	sec.data = make([dynamic]u8, 0, b.allocator)
	sec.relos = make([dynamic]Relocation, 0, b.allocator)

	if b.sections == nil {
		b.sections = make([dynamic]^Section, 0, b.allocator)
	}
	append(&b.sections, sec)
	return Section_Handle(u32(len(b.sections)))
}

/*
	Appends a copy of `data` to a section's content.  The builder owns the
	copy; the caller keeps ownership of `data`.
*/
section_add_data :: proc(b: ^Builder, sec: Section_Handle, data: []byte) -> Error {
	s := get_section(b, sec)
	if s == nil {
		return .Unknown_Section
	}
	if len(data) == 0 {
		return nil
	}

	append(&s.data, ..data)
	return nil
}

/*
	For `SHT_NOBITS` sections: sizes the section to exactly `byte_count`
	zeroed bytes and returns a view through which the caller can write
	content into the builder-owned data.  For other section types this is
	a `Not_Nobits_Section` error.
*/
section_reserve :: proc(b: ^Builder, sec: Section_Handle, byte_count: int) -> ([]byte, Error) {
	s := get_section(b, sec)
	if s == nil {
		return nil, .Unknown_Section
	}
	if s.sh_type != .SHT_NOBITS || byte_count < 0 {
		return nil, .Not_Nobits_Section
	}

	free_dynamic(s.data)
	s.data = make([dynamic]u8, byte_count, b.allocator)
	return s.data[:], nil
}

/*
	Returns the section table index the section handle occupies, to be
	used as a symbol's `shndx`.  The handle must come from the same
	builder; there is no validation of the handle itself.
*/
section_index :: proc(sec: Section_Handle) -> Section_Index {
	return Section_Index(u16(u32(sec)))
}

/*
	Adds a symbol.  The name is cloned into the builder; an empty name is
	allowed (ELF has unnamed symbols, e.g. `STT_SECTION` entries).

	`shndx` is a real section table index per `section_index`, or one of
	the spec's reserved values (`SHN_UNDEF` for an undefined symbol,
	`SHN_ABS` for an absolute value).

	Returns a handle to the new symbol.  The zero value is never returned.
*/
add_symbol :: proc(b: ^Builder, name: string, binding: STB, kind: STT, shndx: Section_Index, value: u64, size: u64) -> Symbol_Handle {
	sym := Symbol {
		name    = clone_string(name, b.allocator),
		binding = binding,
		kind    = kind,
		shndx   = shndx,
		value   = value,
		size    = size,
	}
	if b.symbols == nil {
		b.symbols = make([dynamic]Symbol, 0, b.allocator)
	}
	append(&b.symbols, sym)
	return Symbol_Handle(u32(len(b.symbols)))
}

/*
	Requests a relocation with apply address `offset` bytes into the
	target section, referencing `symbol`, with `addend` as the ELF `A`.
	`write` emits it into `.rela.<target section name>`.
*/
add_reloc :: proc(b: ^Builder, target: Section_Handle, symbol: Symbol_Handle, kind: R_X86_64, offset: u64, addend: i64) -> Error {
	sec := get_section(b, target)
	if sec == nil {
		return .Unknown_Section
	}
	if get_symbol(b, symbol) == nil {
		return .Unknown_Symbol
	}

	append(&sec.relos, Relocation{symbol = symbol, kind = kind, offset = offset, addend = addend})
	return nil
}

/*
	Serializes the builder into the bytes of a complete ELF64 relocatable
	object.  Locals are emitted into `.symtab` before global and weak
	symbols; `sh_link`/`sh_info` pairs map `.symtab` to `.strtab`, and each
	`.rela.<section>` to `.symtab` and to its target section.

	`object` is exactly one allocation; the caller owns it and must
	`delete` it with the allocator given here.
*/
write :: proc(b: ^Builder, allocator := context.allocator) -> (object: []u8, err: Error) {
	shstrtab: String_Table
	strtab: String_Table
	string_table_init(&shstrtab, allocator)
	string_table_init(&strtab, allocator)
	defer string_table_destroy(&shstrtab, allocator)
	defer string_table_destroy(&strtab, allocator)

	// Names of generated relocation sections, freed below in one place.
	rela_names: [dynamic]string
	rela_names = make([dynamic]string, 0, allocator)
	defer {
		for name in rela_names {
			free_string(name, allocator)
		}
		free_dynamic(rela_names)
	}

	// Symbol table ordering: entry 0 is the null symbol, then locals in
	// insertion order, then global and weak symbols in insertion order.
	num_local_syms := 0
	for sym in b.symbols {
		if sym.binding == .STB_LOCAL {
			num_local_syms += 1
		}
	}

	// Maps a symbol record to its position in the final `.symtab`.
	symtab_pos := make([dynamic]u32, len(b.symbols), allocator)
	defer free_dynamic(symtab_pos)

	next_local := 1
	next_other := 1 + num_local_syms
	for sym, sym_i in b.symbols {
		if sym.binding == .STB_LOCAL {
			symtab_pos[sym_i] = u32(next_local)
			next_local += 1
		} else {
			symtab_pos[sym_i] = u32(next_other)
			next_other += 1
		}
	}

	for sym in b.symbols {
		if sym.binding == .STB_LOCAL {
			string_table_intern(&strtab, sym.name)
		}
	}
	for sym in b.symbols {
		if sym.binding != .STB_LOCAL {
			string_table_intern(&strtab, sym.name)
		}
	}

	symtab_index := int(len(b.sections)) + 1
	strtab_index := int(len(b.sections)) + 2

	descs := make([dynamic]Section_Desc, 0, allocator)
	defer free_dynamic(descs)

	// Index 0 is always the spec's null section header.
	append(&descs, Section_Desc{})

	for sec in b.sections {
		append(
			&descs,
			Section_Desc {
				name = string_table_intern(&shstrtab, sec.name),
				ty = sec.sh_type,
				flags = section_flags_mask(sec.flags),
				size = u64(len(sec.data)),
				align_ = sec.addralign,
				entsize = sec.entsize,
			},
		)
	}

	// `sh_info` of a symbol table is the index of its first non-local
	// symbol; entry 0 is the null symbol.
	append(
		&descs,
		Section_Desc {
			ty = .SHT_SYMTAB,
			size = u64(SYMBOL_ENTRY_SIZE * (int(len(b.symbols)) + 1)),
			link = u32(strtab_index),
			info = u32(1 + num_local_syms),
			align_ = 8,
			entsize = SYMBOL_ENTRY_SIZE,
		},
	)

	append(&descs, Section_Desc{ty = .SHT_STRTAB, size = u64(len(strtab.storage)), align_ = 1})

	// The symbol table and string tables carry their own names into
	// `.shstrtab`; intern them before the `.shstrtab` descriptor is sized.
	descs[symtab_index].name = string_table_intern(&shstrtab, ".symtab")
	descs[strtab_index].name = string_table_intern(&shstrtab, ".strtab")
	shstrtab_name := string_table_intern(&shstrtab, ".shstrtab")

	// One `.rela.<name>` per section that carries relocations, in section
	// order, so resolver runs walk the table front to back.
	for sec, sec_i in b.sections {
		if len(sec.relos) == 0 {
			continue
		}
		rela_name := concat_string(".rela", sec.name, allocator)
		append(&rela_names, rela_name)
		append(
			&descs,
			Section_Desc {
				name = string_table_intern(&shstrtab, rela_name),
				ty = .SHT_RELA,
				flags = section_flags_mask(Section_Flags{.SHF_INFO_LINK}),
				size = u64(RELA_ENTRY_SIZE * len(sec.relos)),
				link = u32(symtab_index),
				info = u32(sec_i + 1),
				align_ = 8,
				entsize = RELA_ENTRY_SIZE,
			},
		)
	}

	// `.shstrtab` is always the last section.
	shstrndx := len(descs)
	append(&descs, Section_Desc{name = shstrtab_name, ty = .SHT_STRTAB, size = u64(len(shstrtab.storage)), align_ = 1})

	if len(descs) > 0xffff {
		return nil, .Too_Many_Sections
	}

	// Layout: section data in emission order, then the section header
	// table.  `SHT_NOBITS` sections keep `sh_offset` but occupy no bytes
	// in the file.
	cursor: u64 = FHEADER_SIZE
	for desc, desc_i in descs {
		descs[desc_i].off = align_up(cursor, desc.align_)
		if desc.ty != .SHT_NOBITS {
			cursor = descs[desc_i].off + desc.size
		}
	}
	shoff := align_up(cursor, 8)
	total := shoff + u64(SHENTRY_SIZE * len(descs))

	data, data_err := mem.alloc_bytes(int(total), allocator = allocator)
	if data_err != nil {
		return nil, Error(data_err)
	}
	object = data

	for sec, sec_i in b.sections {
		if sec.sh_type != .SHT_NOBITS && len(sec.data) > 0 {
			desc := descs[sec_i + 1]
			copy(object[int(desc.off):], sec.data[:])
		}
	}

	strtab_desc := descs[strtab_index]
	copy(object[int(strtab_desc.off):], strtab.storage[:])

	shstrtab_desc := descs[shstrndx]
	copy(object[int(shstrtab_desc.off):], shstrtab.storage[:])

	// Symbol table entries in the order the names were interned: the null
	// symbol, then locals, then global and weak symbols.
	symtab_desc := descs[symtab_index]
	blit(object, int(symtab_desc.off), Symbol_Entry{})
	pos := int(symtab_desc.off) + SYMBOL_ENTRY_SIZE
	for pass := 0; pass < 2; pass += 1 {
		for sym in b.symbols {
			is_local := sym.binding == .STB_LOCAL
			if (is_local && pass == 0) || (!is_local && pass == 1) {
				blit(
					object,
					pos,
					Symbol_Entry {
						st_name = u32le(u32(string_table_intern(&strtab, sym.name))),
						st_info = u8(sym.binding) << 4 | u8(sym.kind),
						st_shndx = u16le(u16(sym.shndx)),
						st_value = u64le(sym.value),
						st_size = u64le(sym.size),
					},
				)
				pos += SYMBOL_ENTRY_SIZE
			}
		}
	}

	// Relocation entries against their positions in `.symtab`.
	rela_desc_i := symtab_index + 2
	for sec in b.sections {
		if len(sec.relos) == 0 {
			continue
		}
		rela_desc := descs[rela_desc_i]
		rela_desc_i += 1
		pos = int(rela_desc.off)
		for reloc in sec.relos {
			sym_pos := symtab_pos[int(u32(reloc.symbol)) - 1]
			blit(
				object,
				pos,
				Rela_Entry {
					r_offset = u64le(reloc.offset),
					r_info = u64le(u64(sym_pos) << 32 | u64(transmute(u32)(reloc.kind))),
					r_addend = i64le(reloc.addend),
				},
			)
			pos += RELA_ENTRY_SIZE
		}
	}

	hdr_pos := int(shoff)
	for desc in descs {
		blit(
			object,
			hdr_pos,
			Section_Header {
				sh_name = u32le(u32(desc.name)),
				sh_type = desc.ty,
				sh_flags = u64le(desc.flags),
				sh_offset = u64le(desc.off),
				sh_size = u64le(desc.size),
				sh_link = u32le(desc.link),
				sh_info = u32le(desc.info),
				sh_addralign = u64le(desc.align_),
				sh_entsize = u64le(desc.entsize),
			},
		)
		hdr_pos += SHENTRY_SIZE
	}

	blit(
		object,
		0,
		File_Header {
			ident = IDENTITY,
			e_type = .ET_REL,
			e_machine = .EM_X86_64,
			e_version = u32le(EV_CURRENT),
			e_shoff = u64le(shoff),
			e_ehsize = u16le(FHEADER_SIZE),
			e_shentsize = u16le(SHENTRY_SIZE),
			e_shnum = u16le(len(descs)),
			e_shstrndx = u16le(shstrndx),
		},
	)

	return object, nil
}

// ---------------------------------------------------------------- //
// Internals
// ---------------------------------------------------------------- //

// Sizes of the serialized ELF64 table entries.
FHEADER_SIZE :: size_of(File_Header) // 64
SHENTRY_SIZE :: size_of(Section_Header) // 64
SYMBOL_ENTRY_SIZE :: size_of(Symbol_Entry) // 24
RELA_ENTRY_SIZE :: size_of(Rela_Entry) // 24

// The canonical `e_ident` prefix the package writes; the rest is zero.
IDENTITY :: [EI_NIDENT]u8{0x7f, 'E', 'L', 'F', ELFCLASS64, ELFDATA2LSB, EV_CURRENT, 0, 0, 0, 0, 0, 0, 0, 0, 0}

@(private)
clone_string :: proc(s: string, allocator: mem.Allocator) -> string {
	if len(s) == 0 {
		return ""
	}
	buf, alloc_err := mem.alloc_bytes(len(s), allocator = allocator)
	if alloc_err != nil {
		return ""
	}
	copy(buf, s)
	return string(buf)
}

@(private)
free_string :: proc(s: string, allocator: mem.Allocator) {
	if len(s) > 0 {
		mem.free(raw_data(s), allocator)
	}
}

@(private)
concat_string :: proc(a, b: string, allocator: mem.Allocator) -> string {
	buf, alloc_err := mem.alloc_bytes(len(a) + len(b), allocator = allocator)
	if alloc_err != nil {
		return ""
	}
	copy(buf[:len(a)], a)
	copy(buf[len(a):], b)
	return string(buf)
}

@(private)
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
@(private)
String_Table :: struct {
	storage: [dynamic]u8,
	entries: [dynamic]String_Table_Entry,
}

@(private)
string_table_init :: proc(st: ^String_Table, allocator: mem.Allocator) {
	// The empty string always occupies offset 0.
	st.storage = make([dynamic]u8, 1, allocator)
	st.entries = make([dynamic]String_Table_Entry, 0, allocator)
	append(&st.entries, String_Table_Entry{offset = 0, name = ""})
}

@(private)
string_table_destroy :: proc(st: ^String_Table, allocator: mem.Allocator) {
	free_dynamic(st.storage)
	free_dynamic(st.entries)
}

@(private)
string_table_intern :: proc(st: ^String_Table, name: string) -> u64 {
	if len(name) == 0 {
		return 0
	}
	for entry in st.entries {
		if entry.name == name {
			return entry.offset
		}
	}
	offset := u64(len(st.storage))
	append(&st.storage, name)
	append(&st.storage, u8(0))
	append(&st.entries, String_Table_Entry{offset = offset, name = name})
	return offset
}

/*
	One section descriptor while building the object file, transcribed
	into a `Section_Header` on output.  `addr` is always zero for
	relocatable objects.
*/
@(private)
Section_Desc :: struct {
	name:    u64,
	ty:      SHT,
	flags:   u64,
	off:     u64,
	size:    u64,
	link:    u32,
	info:    u32,
	align_:  u64,
	entsize: u64,
}

/*
	Copies the bytes of `src` into `dst` at position `pos`.
*/
@(private)
blit :: proc "contextless" (dst: []byte, pos: int, src: $T) {
	one: [1]T = {src}
	copy(dst[pos:], slice.to_bytes(one[:]))
}

/*
	Rounds `pos` up to a multiple of `a`; `a <= 1` means unconstrained and
	returns `pos` unchanged.
*/
@(private)
align_up :: proc "contextless" (pos: u64, a: u64) -> u64 {
	if a <= 1 {
		return pos
	}
	return (pos + a - 1) &~ (a - 1)
}

/*
	Frees a dynamic array.  A no-op for empty arrays, so a zero struct
	destroys cleanly.
*/
@(private)
free_dynamic :: proc(buf: [dynamic]$T) {
	if len(buf) > 0 {
		delete(buf)
	}
}


@(private)
get_section :: proc "contextless" (b: ^Builder, handle: Section_Handle) -> ^Section {
	h := u32(handle)
	if h == 0 || int(h) > len(b.sections) {
		return nil
	}
	return b.sections[int(h) - 1]
}

@(private)
get_symbol :: proc "contextless" (b: ^Builder, handle: Symbol_Handle) -> ^Symbol {
	h := u32(handle)
	if h == 0 || int(h) > len(b.symbols) {
		return nil
	}
	return &b.symbols[int(h) - 1]
}

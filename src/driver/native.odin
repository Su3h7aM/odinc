package driver

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:thread"
import "oc:amd64"
import "oc:check"
import "oc:ir"
import "oc:link"
import "oc:lower"
import "oc:regalloc"
import "oc:sched"
import "oc:types"

Lower_Failed :: struct {
	count: int,
}

Missing_Main :: struct {}

Select_Failed :: struct {
	err: amd64.Select_Error,
}

Allocate_Failed :: struct {
	err: regalloc.Error,
}

Emit_Failed :: struct {
	err: amd64.Emit_Error,
}

Entry_Emit_Failed :: struct {
	err: amd64.Emit_Error,
}

Stub_Emit_Failed :: struct {
	err: amd64.Emit_Error,
}

Link_Failed :: struct {}

@(private = "file")
Build_Error_Context :: struct {
	function_name:  string,
	stub_name:      string,
	link_error:     link.Link_Error,
	has_link_error: bool,
}

Build_Error :: union {
	Driver_Error,
	runtime.Allocator_Error,
	Lower_Failed,
	Missing_Main,
	Select_Failed,
	Allocate_Failed,
	Emit_Failed,
	Entry_Emit_Failed,
	Stub_Emit_Failed,
	Link_Failed,
	Foreign_Library_Failed,
}

// Slots in the BSS atom that `_start` fills: argc, argv and envp.
@(private = "file")
STARTUP_SLOT_COUNT :: 3

// The Linux thread control block: the self pointer at 0 and the stack guard at 0x28, as base/runtime/tls_linux_no_crt_amd64.asm lays it out.
@(private = "file")
TCB_SIZE :: 48

@(private = "file")
STARTUP_SLOT_NAMES := [STARTUP_SLOT_COUNT]string{"runtime.argc", "runtime.argv", "runtime.envp"}

// Checks and lowers `main_path`, then builds a static Linux executable image. Checker diagnostics and lowering
// errors go to `log`. The caller frees the image with `allocator`.
build_file :: proc(
	odin_root, main_path: string,
	log: io.Writer,
	allocator: runtime.Allocator,
	thread_count: int,
	user_collections: []Collection = nil,
	defines: map[string]string = nil,
	level: types.X86_Level = .V1,
) -> (
	image: []byte,
	err: Build_Error,
) {
	file_error: File_Error
	defer file_error_destroy(&file_error, allocator)
	session, driver_err := check_program(odin_root, main_path, allocator, false, user_collections, defines, level, &file_error)
	defer if session != nil { session_destroy(session) }
	if driver_err == .Check_Failed || driver_err == .Unsupported_Import || driver_err == .Parse_Failed || driver_err == .Import_Cycle {
		write_diagnostics(session, log)
		fmt.wprintfln(log, "check stage failed: %v", driver_err)
	}
	if driver_err != .None {
		if driver_err != .Check_Failed && driver_err != .Unsupported_Import && driver_err != .Parse_Failed && driver_err != .Import_Cycle {
			if file_error.code != nil {
				message := describe_file_error(file_error, allocator)
				defer delete(message, allocator)
				fmt.wprintfln(log, "driver error: %s", message)
			} else {
				fmt.wprintfln(log, "driver error: %v", driver_err)
			}
		}
		return nil, driver_err
	}

	module: ir.Module
	lower_errors, lower_err := lower.lower_program(&session.program, &module, allocator, worker_count = thread_count)
	defer delete(lower_errors, allocator)
	if lower_err != nil {
		write_build_error(log, lower_err)
		return nil, lower_err
	}
	defer ir.module_destroy(&module)
	if len(lower_errors) > 0 {
		write_lower_errors(session, log, lower_errors)
		return nil, Lower_Failed{len(lower_errors)}
	}
	entry_name, entry_error := strings.clone(main_symbol_name(session), virtual.arena_allocator(&module.arena))
	if entry_error != nil { return nil, entry_error }
	foreign_files, foreign_err := load_foreign_files(&session.program, session.build.root, allocator)
	if foreign_err != nil {
		write_build_error(log, foreign_err)
		return nil, foreign_err
	}
	defer foreign_files_destroy(&foreign_files)
	session_destroy(session)
	session = nil
	return build_image(&module, entry_name, log, allocator, thread_count, foreign_files)
}

// The symbol of the main package's `main` procedure; empty when the program has none.
main_symbol_name :: proc(session: ^Session) -> string {
	entity := check.scope_lookup_current(&session.scopes, session.main_scope, "main")
	if entity == 0 || int(entity) >= len(session.program.entity_symbols) { return "" }
	return session.program.symbol_table[session.program.entity_symbols[entity]].name
}

@(private = "file")
destroy_link_error :: proc(link_error: link.Link_Error, allocator: runtime.Allocator) {
	#partial switch value in link_error {
	case link.Undefined_Symbols:
		link.undefined_symbols_destroy(value, allocator)
	}
}

@(private)
write_build_error :: proc(log: io.Writer, err: Build_Error, error_context := Build_Error_Context{}) {
	switch value in err {
	case Driver_Error, runtime.Allocator_Error, Lower_Failed:
		fmt.wprintfln(log, "build failed: %v", value)
	case Missing_Main:
		fmt.wprintfln(log, "build failed: no main procedure")
	case Foreign_Library_Failed:
		if value.code != nil {
			message := describe_file_error(File_Error{operation = "cannot read", path = value.path, code = value.code})
			defer delete(message)
			fmt.wprintfln(log, "build failed: %s", message)
		} else {
			fmt.wprintfln(log, "build failed: foreign library %s %s", value.path, value.reason)
		}
	case Select_Failed:
		fmt.wprintfln(log, "%s: instruction selection failed: %v", error_context.function_name, value.err)
	case Allocate_Failed:
		fmt.wprintfln(log, "%s: register allocation failed: %v", error_context.function_name, value.err)
	case Emit_Failed:
		fmt.wprintfln(log, "%s: machine code emission failed: %v", error_context.function_name, value.err)
	case Entry_Emit_Failed:
		fmt.wprintfln(log, "entry code emission failed: %v", value.err)
	case Stub_Emit_Failed:
		fmt.wprintfln(log, "thread stub %s emission failed: %v", error_context.stub_name, value.err)
	case Link_Failed:
		if error_context.has_link_error {
			fmt.wprintfln(log, "link failed: %v", error_context.link_error)
		} else {
			fmt.wprintfln(log, "link failed")
		}
	}
}

// Symbols are laid out as: `_start`, functions, globals, local blobs of every function, startup slots, externs.
// Atoms follow the same order, so the index of every defined symbol is also its atom index.
build_image :: proc(
	module: ^ir.Module,
	entry_name: string,
	log: io.Writer,
	allocator: runtime.Allocator,
	thread_count: int,
	foreign_files: Foreign_Files,
) -> (
	image: []byte,
	err: Build_Error,
) {
	roots, roots_err := find_module_roots(module, entry_name)
	if roots_err != nil {
		write_build_error(log, roots_err)
		return nil, roots_err
	}
	scratch: virtual.Arena
	if arena_err := virtual.arena_init_growing(&scratch); arena_err != nil {
		fmt.wprintfln(log, "image build: scratch arena allocation failed: %v", arena_err)
		return nil, arena_err
	}
	defer virtual.arena_destroy(&scratch)
	error_context: Build_Error_Context
	defer if err != nil { destroy_link_error(error_context.link_error, allocator) }
	defer if err != nil { write_build_error(log, err, error_context) }
	scratch_allocator := virtual.arena_allocator(&scratch)

	layout := assign_symbol_indices(module, scratch_allocator) or_return
	table: Native_Symbol_Table
	table.symbols = make([]link.Symbol, layout.symbol_count, scratch_allocator) or_return
	table.comdats = make([dynamic]link.Comdat, 0, 0, scratch_allocator) or_return
	startup_atom := layout.blob_base + layout.blob_count
	table.atoms = make([dynamic]link.Atom, startup_atom + 2, startup_atom + 2, scratch_allocator) or_return
	defer {
		for &atom in table.atoms[1:1 + layout.function_count] { amd64.atom_destroy(&atom, allocator) }
	}
	build_symbol_table(module, layout, &table, &error_context, scratch_allocator) or_return
	build_startup_atoms(layout, &table, scratch_allocator) or_return

	// The guarded allocator's mutex lives in this scope: it outlives the link and the atom cleanup below.
	locked: mem.Mutex_Allocator
	mem.mutex_allocator_init(&locked, allocator)
	guarded := mem.mutex_allocator(&locked)
	build_function_atoms(module, layout, &table, &error_context, guarded, thread_count, scratch_allocator) or_return
	table.atoms[0] = build_entry_atom(module, roots, layout, scratch_allocator) or_return

	inputs := []link.Input{{atoms = table.atoms[:], symbols = table.symbols, comdats = table.comdats[:]}}
	linked, link_err := link.link_inputs(inputs, foreign_files.objects[:], foreign_files.archives[:], foreign_files.shared[:], "_start", allocator)
	if link_err != nil {
		error_context.link_error = link_err
		error_context.has_link_error = true
		return nil, Link_Failed{}
	}
	return linked, nil
}

@(private = "file")
Module_Roots :: struct {
	main_index, init_index, fini_index, context_index, args_index: int,
}

@(private = "file")
Symbol_Layout :: struct {
	function_count, global_count, blob_count, extern_count:          int,
	global_base, blob_base, extern_base, startup_base, symbol_count: int,
	function_symbols, global_symbols, blob_symbols, extern_symbols:  []u32,
	module_indices:                                                  amd64.Symbol_Indices,
	function_indices:                                                []amd64.Symbol_Indices,
}

@(private = "file")
Native_Symbol_Table :: struct {
	symbols: []link.Symbol,
	comdats: [dynamic]link.Comdat,
	atoms:   [dynamic]link.Atom,
}

@(private = "file")
find_module_roots :: proc(module: ^ir.Module, entry_name: string) -> (roots: Module_Roots, err: Build_Error) {
	roots.main_index = -1
	for function, index in module.functions {
		if function.name == entry_name { roots.main_index = index }
	}
	if roots.main_index < 0 {
		return roots, Missing_Main{}
	}
	roots.init_index = -1
	for function, index in module.functions {
		if function.name == lower.GLOBAL_INITIALIZER_NAME { roots.init_index = index }
	}
	roots.fini_index = -1
	for function, index in module.functions {
		if function.name == lower.PROGRAM_FINALIZER_NAME { roots.fini_index = index }
	}
	roots.context_index = -1
	roots.args_index = -1
	for global, index in module.globals {
		if global.name == lower.DEFAULT_CONTEXT_NAME { roots.context_index = index }
		if global.name == "runtime.args__" { roots.args_index = index }
	}
	assert(roots.context_index >= 0, "lowering declares the default context global")
	assert(roots.args_index >= 0, "lowering declares the runtime args global")

	return
}

@(private = "file")
assign_symbol_indices :: proc(module: ^ir.Module, scratch_allocator: runtime.Allocator) -> (layout: Symbol_Layout, err: runtime.Allocator_Error) {
	layout.function_count = len(module.functions)
	layout.global_count = len(module.globals)
	layout.blob_count = 0
	for function in module.functions {
		layout.blob_count += len(function.blobs)
	}
	layout.extern_count = len(module.externs)
	layout.global_base = 1 + layout.function_count
	layout.blob_base = layout.global_base + layout.global_count
	layout.extern_base = layout.blob_base + layout.blob_count
	layout.startup_base = layout.extern_base + layout.extern_count
	layout.symbol_count = layout.startup_base + STARTUP_SLOT_COUNT + 1

	layout.function_symbols = make([]u32, layout.function_count, scratch_allocator) or_return
	layout.global_symbols = make([]u32, layout.global_count, scratch_allocator) or_return
	layout.blob_symbols = make([]u32, layout.blob_count, scratch_allocator) or_return
	layout.extern_symbols = make([]u32, layout.extern_count, scratch_allocator) or_return
	for index in 0 ..< layout.function_count { layout.function_symbols[index] = u32(1 + index) }
	for index in 0 ..< layout.global_count { layout.global_symbols[index] = u32(layout.global_base + index) }
	for index in 0 ..< layout.blob_count { layout.blob_symbols[index] = u32(layout.blob_base + index) }
	for index in 0 ..< layout.extern_count { layout.extern_symbols[index] = u32(layout.extern_base + index) }

	layout.module_indices[.Function] = layout.function_symbols
	layout.module_indices[.Global] = layout.global_symbols
	layout.module_indices[.Extern] = layout.extern_symbols
	layout.function_indices = make([]amd64.Symbol_Indices, layout.function_count, scratch_allocator) or_return
	blob_offset := 0
	for function, index in module.functions {
		layout.function_indices[index] = layout.module_indices
		layout.function_indices[index][.Local_Blob] = layout.blob_symbols[blob_offset:blob_offset + len(function.blobs)]
		blob_offset += len(function.blobs)
	}

	return
}

@(private = "file")
build_symbol_table :: proc(
	module: ^ir.Module,
	layout: Symbol_Layout,
	table: ^Native_Symbol_Table,
	error_context: ^Build_Error_Context,
	scratch_allocator: runtime.Allocator,
) -> (
	err: Build_Error,
) {
	table.symbols[0] = link.Symbol {
		name = "_start",
		atom = 0,
	}
	for function, index in module.functions {
		// The name is cloned: the function's arena is destroyed once its atom is emitted.
		name := strings.clone(function.name, scratch_allocator) or_return
		table.symbols[1 + index] = link.Symbol {
			name    = name,
			atom    = u32(1 + index),
			binding = symbol_binding(function.linkage),
		}
		if function.linkage == .Link_Once {
			group_atoms := make([]u32, 1, scratch_allocator) or_return
			group_atoms[0] = u32(1 + index)
			append(&table.comdats, link.Comdat{signature = name, atoms = group_atoms}) or_return
		}
	}
	for global, index in module.globals {
		table.symbols[layout.global_base + index] = link.Symbol {
			name    = global_name(global),
			atom    = u32(layout.global_base + index),
			binding = symbol_binding(global.linkage),
		}
		if global.linkage == .Link_Once {
			group_atoms := make([]u32, 1, scratch_allocator) or_return
			group_atoms[0] = u32(layout.global_base + index)
			append(&table.comdats, link.Comdat{signature = global.name, atoms = group_atoms}) or_return
		}
		table.atoms[layout.global_base + index] = global_atom(global, layout.module_indices, scratch_allocator) or_return
	}
	blob_index := 0
	for function, function_index in module.functions {
		for blob in function.blobs {
			table.symbols[layout.blob_base + blob_index] = link.Symbol {
				name = fmt.aprintf("blob.%d.%d", function_index, blob_index, allocator = scratch_allocator),
				atom = u32(layout.blob_base + blob_index),
			}
			table.atoms[layout.blob_base + blob_index] = blob_atom(blob, layout.function_indices[function_index], scratch_allocator) or_return
			blob_index += 1
		}
	}
	for extern, index in module.externs {
		atom := link.ATOM_UNDEFINED
		stub, emitted, stub_err := emit_thread_stub(extern.name, scratch_allocator)
		if stub_err != nil {
			error_context.stub_name = extern.name
			return Stub_Emit_Failed{stub_err}
		}
		if emitted {
			append(&table.atoms, stub) or_return
			atom = u32(len(table.atoms) - 1)
		}
		table.symbols[layout.extern_base + index] = link.Symbol {
			name = extern.name,
			atom = atom,
		}
	}
	return
}

@(private = "file")
build_startup_atoms :: proc(layout: Symbol_Layout, table: ^Native_Symbol_Table, scratch_allocator: runtime.Allocator) -> (err: runtime.Allocator_Error) {
	startup_atom := layout.blob_base + layout.blob_count
	for name, slot in STARTUP_SLOT_NAMES {
		table.symbols[layout.startup_base + slot] = link.Symbol {
			name   = name,
			atom   = u32(startup_atom),
			offset = u64(8 * slot),
		}
	}
	thread_pointer_symbol := u32(layout.startup_base + STARTUP_SLOT_COUNT)
	table.symbols[thread_pointer_symbol] = link.Symbol {
		name = "runtime.thread_pointer",
		atom = u32(startup_atom + 1),
	}
	table.atoms[startup_atom] = link.Atom {
		section = .Bss,
		align   = 8,
		size    = 8 * STARTUP_SLOT_COUNT,
	}
	thread_pointer_relocs := make([]link.Relocation, 1, scratch_allocator) or_return
	thread_pointer_relocs[0] = link.Relocation {
		offset = 0,
		symbol = thread_pointer_symbol,
		kind   = .R_X86_64_64,
		addend = 0,
	}
	table.atoms[startup_atom + 1] = link.Atom {
		section = .Tcb,
		align   = 8,
		bytes   = make([]byte, TCB_SIZE, scratch_allocator) or_return,
		size    = TCB_SIZE,
		relocs  = thread_pointer_relocs,
	}

	return
}

@(private = "file")
build_function_atoms :: proc(
	module: ^ir.Module,
	layout: Symbol_Layout,
	table: ^Native_Symbol_Table,
	error_context: ^Build_Error_Context,
	guarded: runtime.Allocator,
	thread_count: int,
	scratch_allocator: runtime.Allocator,
) -> (
	err: Build_Error,
) {
	if emit_err, failed_function := emit_function_atoms(
		module.functions[:],
		layout.function_indices,
		table.atoms[1:1 + layout.function_count],
		guarded,
		thread_count,
		scratch_allocator,
		module.microarch,
	); emit_err != nil {
		if failed_function >= 0 { error_context.function_name = module.functions[failed_function].name }
		return emit_err
	}
	return
}

@(private = "file")
build_entry_atom :: proc(
	module: ^ir.Module,
	roots: Module_Roots,
	layout: Symbol_Layout,
	scratch_allocator: runtime.Allocator,
) -> (
	atom: link.Atom,
	err: Build_Error,
) {
	thread_pointer_symbol := u32(layout.startup_base + STARTUP_SLOT_COUNT)
	init_symbol: Maybe(u32)
	if roots.init_index >= 0 { init_symbol = layout.function_symbols[roots.init_index] }
	fini_symbol: Maybe(u32)
	if roots.fini_index >= 0 { fini_symbol = layout.function_symbols[roots.fini_index] }
	tls_header_symbol: Maybe(u32)
	for global, index in module.globals {
		if global.name == "_odin_linux_tls_header" { tls_header_symbol = layout.global_symbols[index] }
	}
	entry_atom, entry_err := amd64.emit_linux_entry(
		amd64.Linux_Entry_Symbols {
			main = layout.function_symbols[roots.main_index],
			init = init_symbol,
			fini = fini_symbol,
			default_context = layout.global_symbols[roots.context_index],
			args = layout.global_symbols[roots.args_index],
			argc = u32(layout.startup_base),
			argv = u32(layout.startup_base + 1),
			envp = u32(layout.startup_base + 2),
			thread_pointer = thread_pointer_symbol,
			tls_header = tls_header_symbol,
		},
		module.microarch,
		scratch_allocator,
	)
	if entry_err != nil { return {}, Entry_Emit_Failed{entry_err} }
	return entry_atom, nil
}

@(private = "file")
symbol_binding :: proc(linkage: ir.Linkage) -> link.Binding {
	switch linkage {
	case .Internal:
		return .Local
	case .Strong:
		return .Global
	case .Weak, .Link_Once:
		return .Weak
	}
	unreachable()
}

// Generated storage is addressed by relocation through its atom, so an empty name keeps it out of `.symtab` and
// `.strtab` while leaving every user and foreign symbol named as before.
@(private = "file")
global_name :: proc(global: ir.Global) -> string {
	return "" if global.anonymous else global.name
}

@(private = "file")
symbol_of :: proc(indices: amd64.Symbol_Indices, reference: ir.Symbol_Ref) -> u32 {
	assert(int(reference.index) < len(indices[reference.space]))
	return indices[reference.space][reference.index]
}

// The synthesized atom defining a referenced thread stub, or no atom for any
// other extern, which links as undefined and fails honestly at link time.
@(private = "file")
emit_thread_stub :: proc(name: string, allocator: runtime.Allocator) -> (atom: link.Atom, emitted: bool, err: amd64.Emit_Error) {
	switch name {
	case "_odin_linux_clone":
		atom, err = amd64.emit_linux_clone(allocator)
		return atom, err == nil, err
	case "_odin_linux_tls_layout":
		atom, err = amd64.emit_linux_tls_layout(allocator)
		return atom, err == nil, err
	case "_odin_linux_rt_sigreturn":
		atom, err = amd64.emit_linux_rt_sigreturn(allocator)
		return atom, err == nil, err
	}
	return {}, false, nil
}

@(private = "file")
global_section :: proc(global: ir.Global) -> link.Section_Kind {
	if global.tls { return .Tdata if len(global.bytes) > 0 else .Tbss }
	if len(global.bytes) == 0 { return .Bss }
	return .Data if global.mutable else .Rodata
}

@(private = "file")
relocations_of :: proc(
	data_relocs: []ir.Data_Reloc,
	indices: amd64.Symbol_Indices,
	allocator: runtime.Allocator,
) -> (
	link_relocations: []link.Relocation,
	err: runtime.Allocator_Error,
) {
	link_relocations = make([]link.Relocation, len(data_relocs), allocator) or_return
	for reloc, index in data_relocs {
		link_relocations[index] = link.Relocation {
			offset = reloc.offset,
			symbol = symbol_of(indices, reloc.target),
			kind   = .R_X86_64_64,
			addend = reloc.addend,
		}
	}
	return
}

// The global's bytes stay borrowed from the module; only the relocations are copied.
@(private = "file")
global_atom :: proc(global: ir.Global, indices: amd64.Symbol_Indices, allocator: runtime.Allocator) -> (atom: link.Atom, err: runtime.Allocator_Error) {
	relocs := relocations_of(global.relocs, indices, allocator) or_return
	atom = link.Atom {
		section = global_section(global),
		align   = global.align,
		bytes   = global.bytes,
		size    = u64(global.size),
		relocs  = relocs,
	}
	return
}

// The bytes are copied: the function's arena is destroyed once its atom is emitted.
@(private = "file")
blob_atom :: proc(blob: ir.Data_Blob, indices: amd64.Symbol_Indices, allocator: runtime.Allocator) -> (atom: link.Atom, err: runtime.Allocator_Error) {
	relocs := relocations_of(blob.relocs, indices, allocator) or_return
	bytes := make([]byte, len(blob.bytes), allocator) or_return
	copy(bytes, blob.bytes)
	atom = link.Atom {
		section = .Rodata,
		align   = blob.align,
		bytes   = bytes,
		size    = u64(len(blob.bytes)),
		relocs  = relocs,
	}
	return
}

@(private = "file", thread_local)
native_scratch: virtual.Arena

@(private = "file")
native_function :: proc(
	function: ^ir.Function,
	indices: amd64.Symbol_Indices,
	allocator: runtime.Allocator,
	microarch: types.X86_Level,
) -> (
	atom: link.Atom,
	err: Build_Error,
) {
	if native_scratch.curr_block == nil {
		virtual.arena_init_growing(&native_scratch) or_return
	}
	defer virtual.arena_free_all(&native_scratch)
	scratch := virtual.arena_allocator(&native_scratch)

	schedule, sched_err := sched.order(function, scratch)
	if sched_err != nil { return {}, sched_err }
	plan := signature_plan(function.signatures[function.signature], scratch) or_return

	machine: amd64.Machine_Function
	select_err := amd64.select_function(&machine, function, &schedule, plan, microarch)
	if select_err.kind != .None { return {}, Select_Failed{select_err} }
	defer amd64.machine_function_destroy(&machine)

	program, program_err := amd64.build_program(&machine, scratch)
	if program_err != nil { return {}, program_err }
	result, allocate_err := regalloc.allocate(&program, scratch)
	if allocate_err.kind != .None { return {}, Allocate_Failed{allocate_err} }

	emitted, emit_err := amd64.emit_function(&machine, &result, indices, allocator)
	if emit_err != nil { return {}, Emit_Failed{emit_err} }
	return emitted, nil
}

@(private = "file")
Emit_Slot :: struct {
	atom: link.Atom,
	err:  Build_Error,
}

@(private = "file")
Emit_Task :: struct {
	function:  ^ir.Function,
	indices:   amd64.Symbol_Indices,
	allocator: runtime.Allocator,
	microarch: types.X86_Level,
	slot:      ^Emit_Slot,
}

@(private = "file")
run_emit_task :: proc(job: ^Emit_Task) {
	if native_scratch.curr_block == nil {
		if init_err := virtual.arena_init_growing(&native_scratch); init_err != nil {
			job.slot.err = init_err
			return
		}
	}
	previous := context.allocator
	context.allocator = virtual.arena_allocator(&native_scratch)
	atom, err := native_function(job.function, job.indices, job.allocator, job.microarch)
	context.allocator = previous
	if err == nil {
		virtual.arena_destroy(&job.function.arena)
	}
	job.slot.atom = atom
	job.slot.err = err
}

@(private = "file")
emit_task_run :: proc(task: thread.Task) {
	run_emit_task(cast(^Emit_Task)task.data)
}

@(private = "file")
emit_thread_fini :: proc(worker: ^thread.Thread, data: rawptr) {
	if native_scratch.curr_block != nil {
		virtual.arena_destroy(&native_scratch)
	}
}

@(private = "file")
emit_function_atoms :: proc(
	functions: []^ir.Function,
	indices: []amd64.Symbol_Indices,
	atoms: []link.Atom,
	allocator: runtime.Allocator,
	thread_count: int,
	scratch: runtime.Allocator,
	microarch: types.X86_Level,
) -> (
	err: Build_Error,
	failed_function: int,
) {
	assert(len(functions) == len(indices) && len(functions) == len(atoms))
	slots, slots_err := make([]Emit_Slot, len(functions), scratch)
	if slots_err != nil { return slots_err, -1 }
	jobs, jobs_err := make([]Emit_Task, len(functions), scratch)
	if jobs_err != nil { return jobs_err, -1 }
	for function, index in functions {
		jobs[index] = Emit_Task {
			function  = function,
			indices   = indices[index],
			allocator = allocator,
			microarch = microarch,
			slot      = &slots[index],
		}
	}
	if thread_count <= 1 {
		for &job in jobs { run_emit_task(&job) }
	} else {
		pool: thread.Pool
		thread.pool_init(&pool, scratch, min(thread_count, len(functions)), nil, nil, emit_thread_fini, nil)
		for _, index in jobs {
			thread.pool_add_task(&pool, allocator, emit_task_run, &jobs[index])
		}
		thread.pool_start(&pool)
		thread.pool_finish(&pool)
		thread.pool_destroy(&pool)
	}
	if native_scratch.curr_block != nil {
		virtual.arena_destroy(&native_scratch)
	}
	for slot, index in slots {
		if slot.err != nil {
			for &cleanup in slots {
				if cleanup.err == nil { amd64.atom_destroy(&cleanup.atom, allocator) }
			}
			return slot.err, index
		}
	}
	for slot, index in slots {
		atoms[index] = slot.atom
	}
	return nil, -1
}

// The inverse of amd64's `select_signature`: the IR signature holds every field the selector reads.
@(private = "file")
signature_plan :: proc(signature: ir.Signature, allocator: runtime.Allocator) -> (plan: types.Abi_Plan, err: runtime.Allocator_Error) {
	plan.convention = types.Abi_Convention(signature.cc)
	plan.variadic = signature.variadic
	plan.params = make([]types.Abi_Param, len(signature.params), allocator) or_return
	for param, index in signature.params {
		plan.params[index] = types.Abi_Param {
			type  = abi_piece(param.type),
			attr  = types.Abi_Attr(param.attr),
			ext   = types.Abi_Extension(param.ext),
			size  = param.size,
			align = param.align,
		}
	}
	plan.results = make([]types.Abi_Result, len(signature.results), allocator) or_return
	for result, index in signature.results {
		plan.results[index] = types.Abi_Result {
			type = abi_piece(result.type),
			ext  = types.Abi_Extension(result.ext),
			size = result.size,
		}
	}
	return plan, nil
}

@(private = "file")
abi_piece :: proc(value: ir.Value_Type) -> types.Abi_Piece {
	#partial switch value {
	case .I8:
		return .I8
	case .I16:
		return .I16
	case .I32:
		return .I32
	case .I64:
		return .I64
	case .F16:
		return .F16
	case .F32:
		return .F32
	case .F64:
		return .F64
	case .V128:
		return .V128
	case .Ptr:
		return .Ptr
	}
	unreachable()
}

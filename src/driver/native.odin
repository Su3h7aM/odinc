package driver

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:mem/virtual"
import "oc:amd64"
import "oc:elf"
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
	function: string,
	err:      amd64.Select_Error,
}

Allocate_Failed :: struct {
	function: string,
	err:      regalloc.Error,
}

Emit_Failed :: struct {
	function: string,
	err:      amd64.Emit_Error,
}

Link_Failed :: struct {
	err: link.Link_Error,
}

Build_Error :: union {
	Driver_Error,
	runtime.Allocator_Error,
	Lower_Failed,
	Missing_Main,
	Select_Failed,
	Allocate_Failed,
	Emit_Failed,
	Link_Failed,
}

// Slots in the BSS atom that `_start` fills: argc, argv and envp.
@(private = "file")
STARTUP_SLOT_COUNT :: 3

@(private = "file")
STARTUP_SLOT_NAMES := [STARTUP_SLOT_COUNT]string{"runtime.argc", "runtime.argv", "runtime.envp"}

// Checks and lowers `main_path`, then builds a static Linux executable image. Checker diagnostics and lowering
// errors go to `log`. The caller frees the image with `allocator`.
build_file :: proc(odin_root, main_path: string, log: io.Writer, allocator: runtime.Allocator) -> (image: []byte, err: Build_Error) {
	session, driver_err := check_program(odin_root, main_path, allocator)
	defer session_destroy(session)
	if driver_err == .Check_Failed { write_diagnostics(session, log) }
	if driver_err != .None {
		if driver_err != .Check_Failed { fmt.wprintfln(log, "driver error: %v", driver_err) }
		return nil, driver_err
	}

	module: ir.Module
	lower_errors, lower_err := lower.lower_program(&session.program, &module, allocator)
	defer delete(lower_errors, allocator)
	if lower_err != nil { return nil, lower_err }
	defer ir.module_destroy(&module)
	if len(lower_errors) > 0 {
		write_lower_errors(session, log, lower_errors)
		return nil, Lower_Failed{len(lower_errors)}
	}
	return build_image(&module, log, allocator)
}

// Writes the failure while the module and the image's scratch names are still alive: the error's strings point into them.
@(private = "file")
write_build_error :: proc(log: io.Writer, err: Build_Error) {
	switch value in err {
	case Driver_Error, runtime.Allocator_Error, Lower_Failed:
		fmt.wprintfln(log, "build failed: %v", value)
	case Missing_Main:
		fmt.wprintfln(log, "build failed: no main procedure")
	case Select_Failed:
		fmt.wprintfln(log, "%s: instruction selection failed: %v", value.function, value.err)
	case Allocate_Failed:
		fmt.wprintfln(log, "%s: register allocation failed: %v", value.function, value.err)
	case Emit_Failed:
		fmt.wprintfln(log, "%s: machine code emission failed: %v", value.function, value.err)
	case Link_Failed:
		fmt.wprintfln(log, "link failed: %v", value.err)
	}
}

// Symbols are laid out as: `_start`, functions, globals, local blobs of every function, startup slots, externs.
// Atoms follow the same order, so the index of every defined symbol is also its atom index.
build_image :: proc(module: ^ir.Module, log: io.Writer, allocator: runtime.Allocator) -> (image: []byte, err: Build_Error) {
	main_index := -1
	for function, index in module.functions {
		if function.name == "main" { main_index = index }
	}
	if main_index < 0 { return nil, Missing_Main{} }
	init_index := -1
	for function, index in module.functions {
		if function.name == lower.GLOBAL_INITIALIZER_NAME { init_index = index }
	}
	fini_index := -1
	for function, index in module.functions {
		if function.name == lower.PROGRAM_FINALIZER_NAME { fini_index = index }
	}
	context_index := -1
	args_index := -1
	for global, index in module.globals {
		if global.name == lower.DEFAULT_CONTEXT_NAME { context_index = index }
		if global.name == "runtime.args__" { args_index = index }
	}
	assert(context_index >= 0, "lowering declares the default context global")
	assert(args_index >= 0, "lowering declares the runtime args global")

	scratch: virtual.Arena
	virtual.arena_init_growing(&scratch) or_return
	defer virtual.arena_destroy(&scratch)
	defer if err != nil { write_build_error(log, err) }
	scratch_allocator := virtual.arena_allocator(&scratch)

	function_count := len(module.functions)
	global_count := len(module.globals)
	blob_count := 0
	for function in module.functions {
		blob_count += len(function.blobs)
	}
	extern_count := len(module.externs)
	global_base := 1 + function_count
	blob_base := global_base + global_count
	extern_base := blob_base + blob_count
	startup_base := extern_base + extern_count
	symbol_count := startup_base + STARTUP_SLOT_COUNT + 1

	function_symbols := make([]u32, function_count, scratch_allocator) or_return
	global_symbols := make([]u32, global_count, scratch_allocator) or_return
	blob_symbols := make([]u32, blob_count, scratch_allocator) or_return
	extern_symbols := make([]u32, extern_count, scratch_allocator) or_return
	for index in 0 ..< function_count { function_symbols[index] = u32(1 + index) }
	for index in 0 ..< global_count { global_symbols[index] = u32(global_base + index) }
	for index in 0 ..< blob_count { blob_symbols[index] = u32(blob_base + index) }
	for index in 0 ..< extern_count { extern_symbols[index] = u32(extern_base + index) }

	module_indices: amd64.Symbol_Indices
	module_indices[.Function] = function_symbols
	module_indices[.Global] = global_symbols
	module_indices[.Extern] = extern_symbols
	function_indices := make([]amd64.Symbol_Indices, function_count, scratch_allocator) or_return
	blob_offset := 0
	for function, index in module.functions {
		function_indices[index] = module_indices
		function_indices[index][.Local_Blob] = blob_symbols[blob_offset:blob_offset + len(function.blobs)]
		blob_offset += len(function.blobs)
	}

	symbols := make([]link.Symbol, symbol_count, scratch_allocator) or_return
	startup_atom := blob_base + blob_count
	atoms := make([]link.Atom, startup_atom + 2, scratch_allocator) or_return
	defer {
		for &atom in atoms[1:1 + function_count] { amd64.atom_destroy(&atom, allocator) }
	}
	symbols[0] = link.Symbol {
		name = "_start",
		atom = 0,
	}
	for function, index in module.functions {
		symbols[1 + index] = link.Symbol {
			name = function.name,
			atom = u32(1 + index),
		}
	}
	for global, index in module.globals {
		symbols[global_base + index] = link.Symbol {
			name = global.name,
			atom = u32(global_base + index),
		}
		relocs := make([]link.Relocation, len(global.relocs), scratch_allocator) or_return
		for reloc, reloc_index in global.relocs {
			relocs[reloc_index] = link.Relocation {
				offset = reloc.offset,
				symbol = symbol_of(module_indices, reloc.target),
				kind   = .R_X86_64_64,
				addend = reloc.addend,
			}
		}
		atoms[global_base + index] = link.Atom {
			section = global_section(global),
			align   = global.align,
			bytes   = global.bytes,
			size    = u64(global.size),
			relocs  = relocs,
		}
	}
	blob_index := 0
	for function, function_index in module.functions {
		for blob in function.blobs {
			symbols[blob_base + blob_index] = link.Symbol {
				name = fmt.aprintf("blob.%d.%d", function_index, blob_index, allocator = scratch_allocator),
				atom = u32(blob_base + blob_index),
			}
			relocs := make([]link.Relocation, len(blob.relocs), scratch_allocator) or_return
			for reloc, reloc_index in blob.relocs {
				relocs[reloc_index] = link.Relocation {
					offset = reloc.offset,
					symbol = symbol_of(function_indices[function_index], reloc.target),
					kind   = .R_X86_64_64,
					addend = reloc.addend,
				}
			}
			atoms[blob_base + blob_index] = link.Atom {
				section = .Rodata,
				align   = blob.align,
				bytes   = blob.bytes,
				size    = u64(len(blob.bytes)),
				relocs  = relocs,
			}
			blob_index += 1
		}
	}
	for extern, index in module.externs {
		symbols[extern_base + index] = link.Symbol {
			name = extern.name,
			atom = link.ATOM_UNDEFINED,
		}
	}
	for name, slot in STARTUP_SLOT_NAMES {
		symbols[startup_base + slot] = link.Symbol {
			name   = name,
			atom   = u32(startup_atom),
			offset = u64(8 * slot),
		}
	}
	thread_pointer_symbol := u32(startup_base + STARTUP_SLOT_COUNT)
	symbols[thread_pointer_symbol] = link.Symbol {
		name = "runtime.thread_pointer",
		atom = u32(startup_atom + 1),
	}
	atoms[startup_atom] = link.Atom {
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
	atoms[startup_atom + 1] = link.Atom {
		section = .Tcb,
		align   = 8,
		bytes   = make([]byte, 8, scratch_allocator) or_return,
		size    = 8,
		relocs  = thread_pointer_relocs,
	}

	for function, index in module.functions {
		atoms[1 + index] = native_function(function, function_indices[index], allocator) or_return
	}
	init_symbol: Maybe(u32)
	if init_index >= 0 { init_symbol = function_symbols[init_index] }
	fini_symbol: Maybe(u32)
	if fini_index >= 0 { fini_symbol = function_symbols[fini_index] }
	atoms[0] = start_atom(
		function_symbols[main_index],
		init_symbol,
		fini_symbol,
		global_symbols[context_index],
		global_symbols[args_index],
		u32(startup_base),
		thread_pointer_symbol,
		scratch_allocator,
	) or_return

	inputs := []link.Input{{atoms = atoms, symbols = symbols}}
	linked, link_err := link.link(inputs, "_start", allocator)
	if link_err != nil { return nil, Link_Failed{link_err} }
	return linked, nil
}

// `_start` stores argc, argv and envp, sets the thread pointer, calls the initializer when there is one, passes the
// default context in rdi, calls `main`, calls the finalizer when there is one, and exits 0.
@(private)
start_atom :: proc(
	main_symbol: u32,
	init_symbol, fini_symbol: Maybe(u32),
	context_symbol, args_symbol, startup, thread_pointer: u32,
	allocator: runtime.Allocator,
) -> (
	atom: link.Atom,
	err: runtime.Allocator_Error,
) {
	code := make([dynamic]byte, allocator) or_return
	relocs := make([dynamic]link.Relocation, allocator) or_return
	append(&code, 0x48, 0x8b, 0x04, 0x24) or_return // mov rax, [rsp]
	start_store_rip(&code, &relocs, {0x48, 0x89, 0x05}, startup) or_return // mov [argc], rax
	append(&code, 0x48, 0x8d, 0x44, 0x24, 0x08) or_return // lea rax, [rsp + 8]
	start_store_rip(&code, &relocs, {0x48, 0x89, 0x05}, startup + 1) or_return // mov [argv], rax
	start_store_rip(&code, &relocs, {0x48, 0x89, 0x05}, args_symbol) or_return // mov [runtime.args__.data], rax
	append(&code, 0x48, 0x8b, 0x0c, 0x24) or_return // mov rcx, [rsp]
	start_rip_operand(&code, &relocs, {0x48, 0x89, 0x0d}, args_symbol, .R_X86_64_PC32, 4) or_return // mov [runtime.args__.len], rcx
	append(&code, 0x48, 0x8b, 0x0c, 0x24) or_return // mov rcx, [rsp]
	append(&code, 0x48, 0x8d, 0x44, 0xcc, 0x10) or_return // lea rax, [rsp + rcx * 8 + 16]
	start_store_rip(&code, &relocs, {0x48, 0x89, 0x05}, startup + 2) or_return // mov [envp], rax
	start_rip_operand(&code, &relocs, {0x48, 0x8d, 0x35}, thread_pointer, .R_X86_64_PC32) or_return // lea rsi, [tp]
	append(&code, 0xbf, 0x02, 0x10, 0, 0, 0xb8, 158, 0, 0, 0, 0x0f, 0x05) or_return // arch_prctl(ARCH_SET_FS, rsi)
	if init, has_init := init_symbol.?; has_init {
		start_rip_operand(&code, &relocs, {0xe8}, init, .R_X86_64_PLT32) or_return
	}
	start_rip_operand(&code, &relocs, {0x48, 0x8d, 0x3d}, context_symbol, .R_X86_64_PC32) or_return // lea rdi, [context]
	start_rip_operand(&code, &relocs, {0xe8}, main_symbol, .R_X86_64_PLT32) or_return
	if fini, has_fini := fini_symbol.?; has_fini {
		start_rip_operand(&code, &relocs, {0xe8}, fini, .R_X86_64_PLT32) or_return
	}
	append(&code, 0xb8, 231, 0, 0, 0, 0x31, 0xff, 0x0f, 0x05) or_return // exit_group(0)
	return link.Atom{section = .Text, align = 16, bytes = code[:], size = u64(len(code)), relocs = relocs[:]}, nil
}

// Appends an instruction ending in a rip-relative 32-bit field that refers to `symbol`.
@(private = "file")
start_rip_operand :: proc(
	code: ^[dynamic]byte,
	relocs: ^[dynamic]link.Relocation,
	opcode: []byte,
	symbol: u32,
	kind: elf.R_X86_64,
	addend: i64 = -4,
) -> runtime.Allocator_Error {
	append(code, ..opcode) or_return
	append(relocs, link.Relocation{offset = u32(len(code)), symbol = symbol, kind = kind, addend = addend}) or_return
	_, err := append(code, 0, 0, 0, 0)
	return err
}

@(private = "file")
start_store_rip :: proc(code: ^[dynamic]byte, relocs: ^[dynamic]link.Relocation, opcode: []byte, symbol: u32) -> runtime.Allocator_Error {
	return start_rip_operand(code, relocs, opcode, symbol, .R_X86_64_PC32)
}

@(private = "file")
symbol_of :: proc(indices: amd64.Symbol_Indices, reference: ir.Symbol_Ref) -> u32 {
	assert(int(reference.index) < len(indices[reference.space]))
	return indices[reference.space][reference.index]
}

@(private = "file")
global_section :: proc(global: ir.Global) -> link.Section_Kind {
	if global.tls { return .Tdata if len(global.bytes) > 0 else .Tbss }
	if len(global.bytes) == 0 { return .Bss }
	return .Data if global.mutable else .Rodata
}

@(private = "file", thread_local)
native_scratch: virtual.Arena

@(private = "file")
native_function :: proc(function: ^ir.Function, indices: amd64.Symbol_Indices, allocator: runtime.Allocator) -> (atom: link.Atom, err: Build_Error) {
	if native_scratch.curr_block == nil {
		virtual.arena_init_growing(&native_scratch) or_return
	}
	defer virtual.arena_free_all(&native_scratch)
	scratch := virtual.arena_allocator(&native_scratch)

	schedule, sched_err := sched.order(function, scratch)
	if sched_err != nil { return {}, sched_err }
	plan := signature_plan(function.signatures[function.signature], scratch) or_return

	machine: amd64.Machine_Function
	select_err := amd64.select_function(&machine, function, &schedule, plan)
	if select_err.kind != .None { return {}, Select_Failed{function.name, select_err} }
	defer amd64.machine_function_destroy(&machine)

	program, program_err := amd64.build_program(&machine, scratch)
	if program_err != nil { return {}, program_err }
	result, allocate_err := regalloc.allocate(&program, scratch)
	if allocate_err.kind != .None { return {}, Allocate_Failed{function.name, allocate_err} }

	emitted, emit_err := amd64.emit_function(&machine, &result, indices, allocator)
	if emit_err != nil { return {}, Emit_Failed{function.name, emit_err} }
	return emitted, nil
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

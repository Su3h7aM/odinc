package driver

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:mem/virtual"
import "oc:amd64"
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
	if driver_err != .None { return nil, driver_err }

	module: ir.Module
	lower_errors, lower_err := lower.lower_program(&session.program, &module, allocator)
	defer delete(lower_errors, allocator)
	if lower_err != nil { return nil, lower_err }
	defer ir.module_destroy(&module)
	if len(lower_errors) > 0 {
		write_lower_errors(session, log, lower_errors)
		return nil, Lower_Failed{len(lower_errors)}
	}
	return build_image(&module, allocator)
}

// Symbols are laid out as: `_start`, functions, globals, local blobs of every function, startup slots, externs.
// Atoms follow the same order, so the index of every defined symbol is also its atom index.
build_image :: proc(module: ^ir.Module, allocator: runtime.Allocator) -> (image: []byte, err: Build_Error) {
	main_index := -1
	for function, index in module.functions {
		if function.name == "main" { main_index = index }
	}
	if main_index < 0 { return nil, Missing_Main{} }
	context_index := -1
	for global, index in module.globals {
		if global.name == lower.DEFAULT_CONTEXT_NAME { context_index = index }
	}
	assert(context_index >= 0, "lowering declares the default context global")

	scratch: virtual.Arena
	virtual.arena_init_growing(&scratch) or_return
	defer virtual.arena_destroy(&scratch)
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
	symbol_count := startup_base + STARTUP_SLOT_COUNT

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
	atoms := make([]link.Atom, startup_atom + 1, scratch_allocator) or_return
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
			name = fmt.aprintf("data.%d", index, allocator = scratch_allocator),
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
	atoms[startup_atom] = link.Atom {
		section = .Bss,
		align   = 8,
		size    = 8 * STARTUP_SLOT_COUNT,
	}

	for function, index in module.functions {
		atoms[1 + index] = native_function(function, function_indices[index], allocator) or_return
	}
	atoms[0] = start_atom(function_symbols[main_index], global_symbols[context_index], u32(startup_base), scratch_allocator) or_return

	inputs := []link.Input{{atoms = atoms, symbols = symbols}}
	linked, link_err := link.link(inputs, "_start", allocator)
	if link_err != nil { return nil, Link_Failed{link_err} }
	return linked, nil
}

// `_start` stores argc, argv and envp from the initial stack, passes the default context in rdi, calls
// `main` and exits 0. Relocations: the three startup slots (`startup`, +1, +2), the context, then `main`.
@(private = "file")
start_atom :: proc(main_symbol, context_symbol, startup: u32, allocator: runtime.Allocator) -> (atom: link.Atom, err: runtime.Allocator_Error) {
	start_code := make([]byte, 60, allocator) or_return
	copy(
		start_code,
		[]byte {
			0x48,
			0x8b,
			0x04,
			0x24,
			0x48,
			0x89,
			0x05,
			0,
			0,
			0,
			0,
			0x48,
			0x8d,
			0x44,
			0x24,
			0x08,
			0x48,
			0x89,
			0x05,
			0,
			0,
			0,
			0,
			0x48,
			0x8b,
			0x0c,
			0x24,
			0x48,
			0x8d,
			0x44,
			0xcc,
			0x10,
			0x48,
			0x89,
			0x05,
			0,
			0,
			0,
			0,
			0x48,
			0x8d,
			0x3d,
			0,
			0,
			0,
			0,
			0xe8,
			0,
			0,
			0,
			0,
			0xb8,
			231,
			0,
			0,
			0,
			0x31,
			0xff,
			0x0f,
			0x05,
		},
	)
	relocs := make([]link.Relocation, 5, allocator) or_return
	relocs[0] = {
		offset = 7,
		symbol = startup,
		kind   = .R_X86_64_PC32,
		addend = -4,
	}
	relocs[1] = {
		offset = 19,
		symbol = startup + 1,
		kind   = .R_X86_64_PC32,
		addend = -4,
	}
	relocs[2] = {
		offset = 35,
		symbol = startup + 2,
		kind   = .R_X86_64_PC32,
		addend = -4,
	}
	relocs[3] = {
		offset = 42,
		symbol = context_symbol,
		kind   = .R_X86_64_PC32,
		addend = -4,
	}
	relocs[4] = {
		offset = 47,
		symbol = main_symbol,
		kind   = .R_X86_64_PLT32,
		addend = -4,
	}
	return link.Atom{section = .Text, align = 16, bytes = start_code, size = u64(len(start_code)), relocs = relocs}, nil
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

@(private = "file")
native_function :: proc(function: ^ir.Function, indices: amd64.Symbol_Indices, allocator: runtime.Allocator) -> (atom: link.Atom, err: Build_Error) {
	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_return
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

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

package lower

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "oc:ir"

// A string initializer is a header {data, length} whose data points at a read-only module blob holding the bytes.
@(private)
global_string_image :: proc(
	module: ^ir.Module,
	text: string,
	relocs: []ir.Data_Reloc,
	allocator: runtime.Allocator,
) -> (
	bytes: []byte,
	out_relocs: []ir.Data_Reloc,
	err: runtime.Allocator_Error,
) {
	index := global_string_blob(module, text) or_return
	bytes = make([]byte, 16, allocator) or_return
	write_scalar(bytes, 8, u64(len(text)), 8)
	out_relocs = make([]ir.Data_Reloc, len(relocs) + 1, allocator) or_return
	copy(out_relocs, relocs)
	out_relocs[len(relocs)] = {
		offset = 0,
		target = ir.Symbol_Ref{space = .Global, index = index},
	}
	return bytes, out_relocs, nil
}

// Appends the bytes of text as a read-only module global and returns its index.
@(private)
global_string_blob :: proc(module: ^ir.Module, text: string) -> (index: u32, err: runtime.Allocator_Error) {
	module_allocator := virtual.arena_allocator(&module.arena)
	index = u32(len(module.globals))
	blob_bytes := make([]byte, len(text), module_allocator) or_return
	copy(blob_bytes, text)
	name := fmt.aprintf("__odinc_internal_string_%d", index, allocator = module_allocator)
	append(&module.globals, ir.Global{name = name, size = u32(len(text)), align = 1, bytes = blob_bytes}) or_return
	return index, nil
}

@(private)
global_cstring_image :: proc(
	module: ^ir.Module,
	text: string,
	relocs: []ir.Data_Reloc,
	allocator: runtime.Allocator,
) -> (
	bytes: []byte,
	out_relocs: []ir.Data_Reloc,
	err: runtime.Allocator_Error,
) {
	index := global_cstring_blob(module, text) or_return
	bytes = make([]byte, 8, allocator) or_return
	out_relocs = make([]ir.Data_Reloc, len(relocs) + 1, allocator) or_return
	copy(out_relocs, relocs)
	out_relocs[len(relocs)] = {
		offset = 0,
		target = ir.Symbol_Ref{space = .Global, index = index},
	}
	return bytes, out_relocs, nil
}

@(private)
global_cstring_blob :: proc(module: ^ir.Module, text: string) -> (index: u32, err: runtime.Allocator_Error) {
	module_allocator := virtual.arena_allocator(&module.arena)
	index = u32(len(module.globals))
	blob_bytes := make([]byte, len(text) + 1, module_allocator) or_return
	copy(blob_bytes, transmute([]byte)text)
	name := fmt.aprintf("__odinc_internal_cstring_%d", index, allocator = module_allocator)
	append(&module.globals, ir.Global{name = name, size = u32(len(blob_bytes)), align = 1, bytes = blob_bytes}) or_return
	return index, nil
}

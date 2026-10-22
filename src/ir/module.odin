package ir

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "oc:types"

Calling_Convention :: enum u8 {
	Odin,
	Contextless,
	C,
}

Extension :: enum u8 {
	None,
	Sign,
	Zero,
}

Param_Attr :: enum u8 {
	Direct,
	Indirect,
	By_Value,
	Struct_Return,
	Context,
}

Param :: struct {
	type:  Value_Type,
	attr:  Param_Attr,
	ext:   Extension,
	size:  u32,
	align: u16,
}

Result :: struct {
	type: Value_Type,
	ext:  Extension,
	size: u32,
}

Signature :: struct {
	cc:       Calling_Convention,
	variadic: bool,
	params:   []Param,
	results:  []Result,
}

Linkage :: enum u8 {
	Internal,
	Strong,
	Weak,
	Link_Once,
}

Symbol_Space :: enum u8 {
	None,
	Function,
	Global,
	Extern,
	Local_Blob,
}

Symbol_Ref :: struct {
	space: Symbol_Space,
	index: u32,
}

Data_Reloc :: struct {
	offset: u32,
	target: Symbol_Ref,
	addend: i64,
}

Global :: struct {
	name:    string,
	linkage: Linkage,
	size:    u32,
	align:   u32,
	mutable: bool,
	tls:     bool,
	bytes:   []byte,
	relocs:  []Data_Reloc,
}

Data_Blob :: struct {
	bytes:  []byte,
	align:  u32,
	relocs: []Data_Reloc,
}

Extern :: struct {
	name: string,
}

// Arrays and data live in `arena`, so a `Module` must not be moved after `module_init`.
Module :: struct {
	functions: [dynamic]^Function,
	globals:   [dynamic]Global,
	externs:   [dynamic]Extern,
	// Global baseline level, copied from the checked program; selectors union it with each function's own set.
	microarch: types.X86_Level,
	arena:     virtual.Arena,
}

module_init :: proc(module: ^Module) -> (err: runtime.Allocator_Error) {
	module^ = {}
	virtual.arena_init_growing(&module.arena) or_return
	defer if err != nil {
		virtual.arena_destroy(&module.arena)
	}

	allocator := virtual.arena_allocator(&module.arena)
	module.functions = make([dynamic]^Function, allocator) or_return
	module.globals = make([dynamic]Global, allocator) or_return
	module.externs = make([dynamic]Extern, allocator) or_return
	return nil
}

// Destroys every function the module holds, then the module arena.
module_destroy :: proc(module: ^Module) {
	for function in module.functions {
		function_destroy(function)
	}
	virtual.arena_destroy(&module.arena)
	module^ = {}
}

// Returns, per function in index order, the global that holds each of its `blobs`. Blobs with equal
// bytes, alignment and relocations (same offsets, targets and addends; a `Local_Blob` target counts
// as equal only within its own function) share one global, appended to `module.globals` in
// first-occurrence order. Relocations of the new globals are rewritten to their final targets.
// Results and globals are allocated in `module.arena`.
blob_merge :: proc(module: ^Module) -> (blob_symbols: [][]Symbol_Ref, err: runtime.Allocator_Error) {
	scratch: virtual.Arena
	virtual.arena_init_growing(&scratch) or_return
	defer virtual.arena_destroy(&scratch)
	scratch_allocator := virtual.arena_allocator(&scratch)

	module_allocator := virtual.arena_allocator(&module.arena)
	blob_symbols = make([][]Symbol_Ref, len(module.functions), module_allocator) or_return

	first_merged := len(module.globals)
	representative_functions := make([dynamic]u32, scratch_allocator) or_return
	global_of_key := make(map[string]u32, scratch_allocator)
	key := make([dynamic]byte, scratch_allocator) or_return

	for function, function_index in module.functions {
		blobs := function.blobs[:]
		blob_symbols[function_index] = make([]Symbol_Ref, len(blobs), module_allocator) or_return
		for blob, blob_index in blobs {
			clear(&key)
			append_blob_key(&key, blob, u32(function_index))
			if global_index, found := global_of_key[string(key[:])]; found {
				blob_symbols[function_index][blob_index] = {.Global, global_index}
				continue
			}

			global_index := u32(len(module.globals))
			append(
				&module.globals,
				Global {
					size = u32(len(blob.bytes)),
					align = blob.align,
					bytes = slice.clone(blob.bytes, module_allocator) or_return,
					relocs = slice.clone(blob.relocs, module_allocator) or_return,
				},
			) or_return
			append(&representative_functions, u32(function_index)) or_return
			global_of_key[strings.clone(string(key[:]), scratch_allocator) or_return] = global_index
			blob_symbols[function_index][blob_index] = {.Global, global_index}
		}
	}

	for function_index, offset in representative_functions {
		global := &module.globals[first_merged + offset]
		for &reloc in global.relocs {
			if reloc.target.space == .Local_Blob {
				reloc.target = blob_symbols[function_index][reloc.target.index]
			}
		}
	}
	return blob_symbols, nil
}

@(private = "file")
append_blob_key :: proc(key: ^[dynamic]byte, blob: Data_Blob, function_index: u32) {
	append_integer(key, blob.align)
	append_integer(key, u64(len(blob.bytes)))
	append(key, ..blob.bytes)
	append_integer(key, u64(len(blob.relocs)))
	for reloc in blob.relocs {
		append_integer(key, reloc.offset)
		append_integer(key, u8(reloc.target.space))
		append_integer(key, reloc.target.index)
		if reloc.target.space == .Local_Blob {
			append_integer(key, function_index)
		}
		append_integer(key, u64(reloc.addend))
	}
}

@(private = "file")
append_integer :: proc(key: ^[dynamic]byte, value: $T) where intrinsics.type_is_integer(T) {
	value := value
	append(key, ..mem.ptr_to_bytes(&value))
}

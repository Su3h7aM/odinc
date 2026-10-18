package ir

import "core:io"
import "core:strconv"

Print_Options :: struct {
	value_prefix: string,
	indent:       string,
}

DEFAULT_PRINT_OPTIONS :: Print_Options {
	value_prefix = "n",
	indent       = "  ",
}

@(private = "file")
CALLING_CONVENTION_NAMES := [Calling_Convention]string {
	.Odin        = "odin",
	.Contextless = "contextless",
	.C           = "c",
}

@(private = "file")
VALUE_TYPE_NAMES := [Value_Type]string {
	.None    = "none",
	.Control = "ctrl",
	.Memory  = "mem",
	.Tuple   = "tuple",
	.Bool    = "bool",
	.I8      = "i8",
	.I16     = "i16",
	.I32     = "i32",
	.I64     = "i64",
	.F16     = "f16",
	.F32     = "f32",
	.F64     = "f64",
	.V128    = "v128",
	.Ptr     = "ptr",
}

@(private = "file")
MEMORY_ORDER_NAMES := [Memory_Order]string {
	.Plain    = "plain",
	.Volatile = "volatile",
	.Relaxed  = "relaxed",
	.Acquire  = "acquire",
	.Release  = "release",
	.Acq_Rel  = "acq_rel",
	.Seq_Cst  = "seq_cst",
}

@(private = "file")
RMW_OP_NAMES := [Rmw_Op]string {
	.Add  = "add",
	.Sub  = "sub",
	.And  = "and",
	.Nand = "nand",
	.Or   = "or",
	.Xor  = "xor",
	.Xchg = "xchg",
}

// Writes the module in the text form of `docs/02-ir-design.md` section 10: globals, externs, then
// functions, in index order. Every node is printed by id; removed nodes are skipped.
print_module :: proc(w: io.Writer, module: ^Module, options := DEFAULT_PRINT_OPTIONS) -> io.Error {
	for global, index in module.globals {
		print_global(w, index, global, options) or_return
	}
	for extern, index in module.externs {
		put(w, "extern e") or_return
		put_int(w, i64(index)) or_return
		put(w, " ") or_return
		put_quoted(w, extern.name) or_return
		put(w, "\n") or_return
	}
	for function in module.functions {
		print_function(w, function, options) or_return
	}
	return nil
}

print_function :: proc(w: io.Writer, function: ^Function, options := DEFAULT_PRINT_OPTIONS) -> io.Error {
	put(w, "func f") or_return
	put_int(w, i64(function.id)) or_return
	put(w, " ") or_return
	put_quoted(w, function.name) or_return
	put(w, " sig=s") or_return
	put_int(w, i64(function.signature)) or_return
	put(w, " {\n") or_return

	for signature, index in function.signatures {
		print_signature(w, index, signature, options) or_return
	}
	for values, index in function.tables {
		print_table(w, index, values, options) or_return
	}
	for blob, index in function.blobs {
		print_blob(w, index, blob, options) or_return
	}
	for id in 1 ..< len(function.nodes) {
		if function.nodes.kind[id] == .Removed {
			continue
		}
		print_node_line(w, function, Node_Id(id), options) or_return
	}
	put(w, "}\n") or_return
	return nil
}

@(private = "file")
print_global :: proc(w: io.Writer, index: int, global: Global, options: Print_Options) -> io.Error {
	put(w, "global g") or_return
	put_int(w, i64(index)) or_return
	put(w, " ") or_return
	put_quoted(w, global.name) or_return
	put(w, " size ") or_return
	put_int(w, i64(global.size)) or_return
	put(w, " align ") or_return
	put_int(w, i64(global.align)) or_return
	if global.mutable {
		put(w, " mut") or_return
	}
	if global.tls {
		put(w, " tls") or_return
	}
	if global.bytes != nil {
		put(w, " bytes") or_return
		print_hex_bytes(w, global.bytes) or_return
	}
	put(w, "\n") or_return
	print_relocs(w, global.relocs, 1, options) or_return
	return nil
}

@(private = "file")
print_signature :: proc(w: io.Writer, index: int, signature: Signature, options: Print_Options) -> io.Error {
	write_indent(w, 1, options) or_return
	put(w, "sig s") or_return
	put_int(w, i64(index)) or_return
	put(w, " cc ") or_return
	put(w, CALLING_CONVENTION_NAMES[signature.cc]) or_return
	if signature.variadic {
		put(w, " variadic") or_return
	}
	put(w, " (") or_return
	for param, position in signature.params {
		if position > 0 {
			put(w, ", ") or_return
		}
		print_param(w, param) or_return
	}
	put(w, ") -> (") or_return
	for result, position in signature.results {
		if position > 0 {
			put(w, ", ") or_return
		}
		put(w, VALUE_TYPE_NAMES[result.type]) or_return
		print_extension(w, result.ext) or_return
	}
	put(w, ")\n") or_return
	return nil
}

@(private = "file")
print_param :: proc(w: io.Writer, param: Param) -> io.Error {
	put(w, VALUE_TYPE_NAMES[param.type]) or_return
	switch param.attr {
	case .Direct:
		if param.align != 0 {
			put(w, ":align(") or_return
			put_int(w, i64(param.align)) or_return
			put(w, ")") or_return
		}
	case .Indirect:
		put(w, ":indirect") or_return
	case .By_Value:
		put(w, ":byval(") or_return
		put_int(w, i64(param.size)) or_return
		put(w, ", ") or_return
		put_int(w, i64(param.align)) or_return
		put(w, ")") or_return
	case .Struct_Return:
		put(w, ":sret") or_return
	case .Context:
		put(w, ":context") or_return
	}
	return print_extension(w, param.ext)
}

@(private = "file")
print_extension :: proc(w: io.Writer, ext: Extension) -> io.Error {
	switch ext {
	case .None:
	case .Sign:
		return put(w, ":sext")
	case .Zero:
		return put(w, ":zext")
	}
	return nil
}

@(private = "file")
print_table :: proc(w: io.Writer, index: int, values: []i64, options: Print_Options) -> io.Error {
	write_indent(w, 1, options) or_return
	put(w, "table t") or_return
	put_int(w, i64(index)) or_return
	put(w, " [") or_return
	for value, position in values {
		if position > 0 {
			put(w, ", ") or_return
		}
		put_int(w, value) or_return
	}
	put(w, "]\n") or_return
	return nil
}

@(private = "file")
print_blob :: proc(w: io.Writer, index: int, blob: Data_Blob, options: Print_Options) -> io.Error {
	write_indent(w, 1, options) or_return
	put(w, "blob b") or_return
	put_int(w, i64(index)) or_return
	put(w, " align ") or_return
	put_int(w, i64(blob.align)) or_return
	put(w, " bytes") or_return
	print_hex_bytes(w, blob.bytes) or_return
	put(w, "\n") or_return
	print_relocs(w, blob.relocs, 2, options) or_return
	return nil
}

@(private = "file")
print_relocs :: proc(w: io.Writer, relocs: []Data_Reloc, depth: int, options: Print_Options) -> io.Error {
	for reloc in relocs {
		write_indent(w, depth, options) or_return
		put(w, "reloc ") or_return
		put_int(w, i64(reloc.offset)) or_return
		put(w, " -> ") or_return
		print_symbol_ref(w, reloc.target) or_return
		if reloc.addend > 0 {
			put(w, " + ") or_return
			put_int(w, reloc.addend) or_return
		} else if reloc.addend < 0 {
			put(w, " - ") or_return
			put_int(w, -reloc.addend) or_return
		}
		put(w, "\n") or_return
	}
	return nil
}

print_node_line :: proc(w: io.Writer, function: ^Function, id: Node_Id, options := DEFAULT_PRINT_OPTIONS) -> io.Error {
	kind := function.nodes.kind[id]
	write_indent(w, 1, options) or_return
	put(w, options.value_prefix) or_return
	put_int(w, i64(id)) or_return
	put(w, " = ") or_return
	put(w, kind_info[kind].name) or_return
	put(w, ".") or_return
	put(w, VALUE_TYPE_NAMES[function.nodes.type[id]]) or_return
	for input, slot in node_inputs(function, id) {
		put(w, " " if slot == 0 else ", ") or_return
		print_node_ref(w, input, options) or_return
	}
	print_attributes(w, function, id) or_return
	put(w, "\n") or_return
	return nil
}

@(private = "file")
print_attributes :: proc(w: io.Writer, function: ^Function, id: Node_Id) -> io.Error {
	kind := function.nodes.kind[id]
	data := function.nodes.data[id]
	#partial switch kind {
	case .Const_Int:
		put(w, " value=") or_return
		put_int(w, data.int_value) or_return
	case .Ptr_Offset:
		put(w, " offset=") or_return
		put_int(w, data.int_value) or_return
	case .Const_Float:
		put(w, " bits=") or_return
		put_hex(w, data.float_bits) or_return
	case .Proj:
		put(w, " index=") or_return
		put_int(w, i64(data.index)) or_return
	case .Ptr_Index:
		put(w, " stride=") or_return
		put_int(w, i64(data.index)) or_return
	case .Stack_Alloc:
		put(w, " align=") or_return
		put_int(w, i64(data.index)) or_return
	case .Switch:
		put(w, " table=t") or_return
		put_int(w, i64(data.index)) or_return
	case .Call:
		put(w, " sig=s") or_return
		put_int(w, i64(data.index)) or_return
	case .Target_Op:
		put(w, " op=") or_return
		put(w, target_op_info[Target_Op(data.index)].name) or_return
	case .Mem_Set:
		if data.access.order != .Plain {
			put(w, " order=") or_return
			put(w, MEMORY_ORDER_NAMES[data.access.order]) or_return
		}
	case .Symbol_Addr, .Tls_Addr:
		put(w, " sym=") or_return
		print_symbol_ref(w, data.symbol) or_return
	case .Stack_Slot:
		put(w, " size=") or_return
		put_int(w, i64(data.slot.size)) or_return
		put(w, " align=") or_return
		put_int(w, i64(data.slot.align)) or_return
	case .Load, .Load_Ordered, .Store, .Atomic_Rmw, .Atomic_Cas, .Fence:
		if kind != .Fence {
			put(w, " align=") or_return
			put_int(w, i64(1) << data.access.align_log2) or_return
		}
		put(w, " order=") or_return
		put(w, MEMORY_ORDER_NAMES[data.access.order]) or_return
		#partial switch kind {
		case .Atomic_Rmw:
			put(w, " op=") or_return
			put(w, RMW_OP_NAMES[data.access.rmw]) or_return
		case .Atomic_Cas:
			put(w, " failure=") or_return
			put(w, MEMORY_ORDER_NAMES[data.access.failure_order]) or_return
			if data.access.weak {
				put(w, " weak") or_return
			}
		case .Fence:
			if data.access.signal {
				put(w, " signal") or_return
			}
		}
	}
	if .Cold in function.nodes.flags[id] {
		put(w, " cold") or_return
	}
	if .Rematerialize in function.nodes.flags[id] {
		put(w, " remat") or_return
	}
	return nil
}

@(private = "file")
print_node_ref :: proc(w: io.Writer, id: Node_Id, options: Print_Options) -> io.Error {
	if id == NODE_NONE {
		return put(w, "_")
	}
	put(w, options.value_prefix) or_return
	return put_int(w, i64(id))
}

@(private = "file")
print_symbol_ref :: proc(w: io.Writer, ref: Symbol_Ref) -> io.Error {
	switch ref.space {
	case .None:
		return put(w, "_")
	case .Function:
		put(w, "f") or_return
	case .Global:
		put(w, "g") or_return
	case .Extern:
		put(w, "e") or_return
	case .Local_Blob:
		put(w, "b") or_return
	}
	return put_int(w, i64(ref.index))
}

@(private = "file")
print_hex_bytes :: proc(w: io.Writer, bytes: []byte) -> io.Error {
	if len(bytes) == 0 {
		return nil
	}
	put(w, " ") or_return
	for value in bytes {
		if value < 0x10 {
			io.write_byte(w, '0') or_return
		}
		put_uint(w, u64(value), 16) or_return
	}
	return nil
}

@(private = "file")
write_indent :: proc(w: io.Writer, depth: int, options: Print_Options) -> io.Error {
	for _ in 0 ..< depth {
		put(w, options.indent) or_return
	}
	return nil
}

@(private = "file")
put :: proc(w: io.Writer, text: string) -> io.Error {
	_, err := io.write_string(w, text)
	return err
}

@(private = "file")
put_int :: proc(w: io.Writer, value: i64) -> io.Error {
	buf: [24]byte
	return put(w, strconv.write_int(buf[:], value, 10))
}

@(private = "file")
put_uint :: proc(w: io.Writer, value: u64, base: int) -> io.Error {
	buf: [24]byte
	return put(w, strconv.write_uint(buf[:], value, base))
}

@(private = "file")
put_hex :: proc(w: io.Writer, value: u64) -> io.Error {
	put(w, "0x") or_return
	return put_uint(w, value, 16)
}

@(private = "file")
put_quoted :: proc(w: io.Writer, text: string) -> io.Error {
	put(w, "\"") or_return
	put(w, text) or_return
	return put(w, "\"")
}

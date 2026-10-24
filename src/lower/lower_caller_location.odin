package lower

import "core:mem/virtual"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Source_Code_Location is { file_path: string, line, column: i32, procedure: string }.
@(private)
SOURCE_CODE_LOCATION_SIZE :: 40

// lower_caller_location builds the location of the call at node, as a default argument of that call.
@(private)
lower_caller_location :: proc(state: ^Procedure_State, node: syntax.Node_Index, type: types.Type_Id) -> ir.Node_Id {
	job := state.job
	layout := job.layouts[type]
	if layout.error != .None || layout.size != SOURCE_CODE_LOCATION_SIZE || lower_type(state, type).kind != .Struct {
		return lower_fail(state, node, .Call_Argument)
	}
	function := job.function
	file := job.program.files[job.procedure.body.file]
	assert(len(file.lines.starts) > 0, "file has no line table")
	line, column := syntax.line_col(file.lines, state.ast.nodes[node].start)
	procedure_name := job.program.entities[job.procedure.entity].name
	allocator := virtual.arena_allocator(&function.arena)
	bytes, bytes_error := make([]byte, SOURCE_CODE_LOCATION_SIZE, allocator)
	if bytes_error != nil {
		function.error = bytes_error
		return 0
	}
	relocations := make([dynamic]ir.Data_Reloc, allocator)
	sink := Image_Sink {
		function = function,
	}
	file_target, file_error := string_sink_blob(sink, file.path, false, 1)
	procedure_target, procedure_error := string_sink_blob(sink, procedure_name, false, 1)
	if file_error != nil || procedure_error != nil {
		function.error = file_error if file_error != nil else procedure_error
		return 0
	}
	append(&relocations, ir.Data_Reloc{offset = 0, target = file_target})
	append(&relocations, ir.Data_Reloc{offset = 24, target = procedure_target})
	put_little_endian(bytes, 8, 8, u64(len(file.path)))
	put_little_endian(bytes, 16, 4, u64(line))
	put_little_endian(bytes, 20, 4, u64(column))
	put_little_endian(bytes, 32, 8, u64(len(procedure_name)))
	blob := ir.Symbol_Ref {
		space = .Local_Blob,
		index = u32(len(function.blobs)),
	}
	if _, append_error := append(&function.blobs, ir.Data_Blob{bytes = bytes, align = 8, relocs = relocations[:]}); append_error != nil {
		function.error = append_error
		return 0
	}
	slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
	lower_store(state, slot, ir.symbol_addr(function, blob), type)
	return slot
}

@(private)
put_little_endian :: proc(bytes: []byte, offset, width: int, value: u64) {
	for index in 0 ..< width {
		bytes[offset + index] = byte(value >> (8 * uint(index)))
	}
}

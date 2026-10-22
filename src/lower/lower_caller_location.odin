package lower

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
	slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
	lower_store_string(state, slot, file.path)
	lower_store_word(state, ir.ptr_offset(function, slot, 16), ir.const_int(function, .I32, i64(line)))
	lower_store_word(state, ir.ptr_offset(function, slot, 20), ir.const_int(function, .I32, i64(column)))
	lower_store_string(state, ir.ptr_offset(function, slot, 24), procedure_name)
	return slot
}

@(private)
lower_store_string :: proc(state: ^Procedure_State, address: ir.Node_Id, text: string) {
	function := state.job.function
	header := lower_string(state, text)
	lower_store_word(state, address, lower_load_word(state, header, .Ptr))
	lower_store_word(state, ir.ptr_offset(function, address, 8), lower_load_word(state, ir.ptr_offset(function, header, 8), .I64))
}

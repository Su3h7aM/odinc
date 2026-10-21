package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// A source parameter spans consecutive physical parameters when it is an aggregate in registers.
@(private)
parameter_span :: proc(parameters: []types.Abi_Param) -> int {
	count := 1
	for count < len(parameters) && parameters[0].source >= 0 && parameters[count].source == parameters[0].source {
		count += 1
	}
	return count
}

@(private)
source_index :: proc(parameters: []types.Abi_Param, source: int) -> int {
	for parameter, index in parameters {
		if int(parameter.source) == source { return index }
	}
	return -1
}

@(private)
struct_return_index :: proc(parameters: []types.Abi_Param) -> int {
	for parameter, index in parameters {
		if parameter.attr == .Struct_Return { return index }
	}
	return -1
}

@(private)
piece_width :: proc(type: ir.Value_Type) -> i64 {
	#partial switch type {
	case .I8:
		return 1
	case .I16, .F16:
		return 2
	case .I32, .F32:
		return 4
	case .I64, .F64, .Ptr:
		return 8
	case .V128:
		return 16
	}
	return 0
}

// The pieces must cover the object exactly, each occupying its size; a narrow scalar fills its eightbyte.
@(private)
parameters_tile :: proc(parameters: []types.Abi_Param, size: i64) -> bool {
	offset := i64(0)
	for parameter in parameters {
		width := piece_width(piece_type(parameter.type))
		if parameter.attr != .Direct || width == 0 || width > i64(parameter.size) { return false }
		offset = next_piece_offset(i64(parameter.size), offset)
	}
	return offset == (size + 7) / 8 * 8
}

// A piece narrower than an eightbyte fills its eightbyte, so the next piece starts at the boundary.
// Only the last piece of an aggregate can be narrower, so the rounding never separates two pieces.
@(private)
next_piece_offset :: proc(piece_size: i64, offset: i64) -> i64 {
	end := offset + piece_size
	if piece_size < 8 { return (end + 7) / 8 * 8 }
	return end
}

@(private)
results_tile :: proc(results: []ir.Result, size: i64) -> bool {
	offset := i64(0)
	for result in results {
		width := piece_width(result.type)
		if width == 0 || width > i64(result.size) { return false }
		offset = next_piece_offset(i64(result.size), offset)
	}
	return offset == (size + 7) / 8 * 8
}

@(private)
is_aggregate :: proc(state: ^Procedure_State, type: types.Type_Id) -> bool {
	if is_wide_integer(state, type) { return true }
	#partial switch lower_type(state, type).kind {
	case .Struct,
	     .Array,
	     .Enumerated_Array,
	     .Fixed_Capacity_Array,
	     .String,
	     .String16,
	     .Slice,
	     .Dynamic_Array,
	     .Map,
	     .Any,
	     .Union,
	     .Complex,
	     .Quaternion,
	     .Simd_Vector,
	     .Matrix:
		return true
	}
	return false
}

// bind_parameter binds one source parameter from its physical pieces; false means an error was reported.
@(private)
bind_parameter :: proc(state: ^Procedure_State, parameters: []types.Abi_Param, values: []ir.Node_Id) -> bool {
	job := state.job
	first := parameters[0]
	if first.source < 0 || int(first.source) >= len(job.procedure.parameters) {
		report_procedure_error(job, .Unsupported, .Parameter)
		return false
	}
	entity := job.procedure.parameters[first.source]
	if state.locals[entity].kind != .None {
		report_procedure_error(job, .Unsupported, .Parameter)
		return false
	}
	type := job.program.entities[entity].type
	if is_aggregate(state, type) { return bind_aggregate_parameter(state, entity, parameters, values) }
	if len(parameters) != 1 || first.attr != .Direct {
		report_procedure_error(job, .Unsupported, .Parameter)
		return false
	}
	value := values[0]
	#partial switch lower_type(state, type).kind {
	case .Bool:
		value = ir.convert(job.function, .Trunc, value, .Bool)
	case .Integer, .Enum, .Bit_Field, .Bit_Set, .Rune, .Float, .Raw_Pointer, .Pointer, .Multi_Pointer, .CString, .CString16, .Procedure, .Type_Id:
	case:
		report_procedure_error(job, .Unsupported, .Parameter)
		return false
	}
	bind_local(state, entity, value, true)
	return !state.failed && job.function.error == nil
}

// An Indirect aggregate is copied from the caller's object, so the callee may change its copy.
@(private)
bind_aggregate_parameter :: proc(state: ^Procedure_State, entity: check.Entity_Id, parameters: []types.Abi_Param, values: []ir.Node_Id) -> bool {
	job := state.job
	if len(parameters) == 1 && (parameters[0].attr == .Indirect || parameters[0].attr == .By_Value) {
		bind_local(state, entity, values[0], true)
	} else {
		layout := job.layouts[job.program.entities[entity].type]
		if layout.error != .None || !parameters_tile(parameters, layout.size) {
			report_procedure_error(job, .Unsupported, .Parameter)
			return false
		}
		bind_local(state, entity, 0, false)
		if state.failed || job.function.error != nil { return false }
		address := state.locals[entity].address
		offset := i64(0)
		for parameter, index in parameters {
			lower_store_word(state, ir.ptr_offset(job.function, address, offset), values[index])
			offset = next_piece_offset(i64(parameter.size), offset)
		}
	}
	return !state.failed && job.function.error == nil
}

// The aggregate is its address: an Indirect or By_Value parameter receives the address, a register one a load per piece.
@(private)
pass_aggregate_argument :: proc(
	state: ^Procedure_State,
	value: ir.Node_Id,
	type: types.Type_Id,
	parameters: []types.Abi_Param,
	arguments: []ir.Node_Id,
) -> bool {
	function := state.job.function
	if len(parameters) == 1 && (parameters[0].attr == .Indirect || parameters[0].attr == .By_Value) {
		arguments[0] = value
		return true
	}
	layout := state.job.layouts[type]
	if layout.error != .None || !parameters_tile(parameters, layout.size) { return false }
	offset := i64(0)
	for parameter, index in parameters {
		arguments[index] = lower_load_word(state, ir.ptr_offset(function, value, offset), piece_type(parameter.type))
		offset = next_piece_offset(i64(parameter.size), offset)
	}
	return true
}

// lower_last_result returns the last value of a return: a scalar directly, an aggregate through the struct return pointer or in registers piece by piece.
@(private)
lower_last_result :: proc(state: ^Procedure_State, node: syntax.Node_Index, value: ir.Node_Id, type: types.Type_Id) {
	if state.failed || state.job.function.error != nil { return }
	if scalar_type(state, type) != .None {
		lower_scalar_return(state, node, value)
		return
	}
	if state.struct_return != 0 {
		lower_store(state, state.struct_return, value, type)
		run_deferred(state, 0)
		if state.failed || state.job.function.error != nil || state.builder.control == 0 { return }
		ir.emit_return(state.builder)
		return
	}
	function := state.job.function
	signature := function.signatures[function.signature]
	layout := state.job.layouts[type]
	if layout.error != .None || len(signature.results) > 2 || !results_tile(signature.results, layout.size) {
		lower_fail(state, node, .Result)
		return
	}
	pieces: [2]ir.Node_Id
	offset := i64(0)
	for result, index in signature.results {
		pieces[index] = lower_load_word(state, ir.ptr_offset(function, value, offset), result.type)
		offset = next_piece_offset(i64(result.size), offset)
	}
	run_deferred(state, 0)
	if state.failed || function.error != nil || state.builder.control == 0 { return }
	ir.emit_return(state.builder, ..pieces[:len(signature.results)])
}

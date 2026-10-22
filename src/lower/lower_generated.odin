package lower

import "base:runtime"
import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:types"

// Map hashers and equality procedures; every child value is inlined, so one procedure serves one key type.
@(private)
lower_generated_procedure :: proc(job: ^Procedure_Job) -> runtime.Allocator_Error {
	function := job.function
	entry := ir.start(function)
	if function.error != nil { return function.error }
	builder := ir.builder_make(function.allocator, function, entry) or_return
	defer ir.builder_destroy(builder)
	state := Procedure_State {
		job           = job,
		builder       = builder,
		entry_control = entry.control,
	}
	generated := job.procedure.generated
	if len(entry.params) != 2 {
		lower_fail(&state, job.procedure.body.node, .Map_Info_Hasher)
		return job.allocation_error
	}
	if generated.kind == .Hasher {
		ir.emit_return(builder, generated_hash_value(&state, generated.type, entry.params[0], entry.params[1]))
	} else {
		result := generated_equal_value(&state, generated.type, entry.params[0], entry.params[1])
		if function.nodes.type[result] == .Bool { result = ir.convert(function, .Zext, result, .I8) }
		ir.emit_return(builder, result)
	}
	if state.failed { return job.allocation_error }
	switch finish_error in ir.builder_finish(builder) {
	case runtime.Allocator_Error:
		return finish_error
	case ir.Verify_Code:
		if finish_error != .None {
			report_procedure_error(job, .Verification, .None, verify_code = finish_error)
		}
	case nil:
	}
	return job.allocation_error
}

@(private = "file")
generated_unsupported :: proc(state: ^Procedure_State) -> ir.Node_Id {
	return lower_fail(state, state.job.procedure.body.node, .Map_Info_Hasher)
}

@(private = "file")
generated_hash_value :: proc(state: ^Procedure_State, type: types.Type_Id, address, seed: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	resolved := types.resolve_named(store, type)
	size, _, _ := types.layout(store, resolved)
	if types.is_simple_compare(store, resolved) {
		return generated_helper_call(state, "default_hasher_fixed", []ir.Node_Id{address, seed, ir.const_int(function, .I64, size)})
	}
	kind := types.get(store, resolved).kind
	#partial switch kind {
	case .String:
		return generated_helper_call(state, "default_hasher_string", []ir.Node_Id{address, seed})
	case .String16:
		return generated_helper_call(state, "default_hasher_string16", []ir.Node_Id{address, seed})
	case .CString:
		return generated_helper_call(state, "default_hasher_cstring", []ir.Node_Id{address, seed})
	case .CString16:
		return generated_helper_call(state, "default_hasher_cstring16", []ir.Node_Id{address, seed})
	case .Float:
		if size == 2 {
			// Widening a half is exact, so equal halves hash equal, like every wider float.
			wide := float16_widen(function, lower_load_word(state, address, .I16))
			return generated_helper_call(state, "default_hasher_f64", []ir.Node_Id{ir.convert(function, .Float_Ext, wide, .F64), seed})
		}
		if size != 4 && size != 8 { return generated_unsupported(state) }
		value := lower_load(state, address, resolved)
		if size == 4 { value = ir.convert(function, .Float_Ext, value, .F64) }
		return generated_helper_call(state, "default_hasher_f64", []ir.Node_Id{value, seed})
	case .Complex:
		return generated_hash_parts(state, address, size / 2, 2, seed)
	case .Quaternion:
		return generated_hash_parts(state, address, size / 4, 4, seed)
	case .Struct:
		fields := types.get(store, resolved).fields
		result := seed
		for field, index in fields {
			offset, _ := types.field_offset(store, resolved, index)
			result = generated_hash_value(state, field.type, ir.ptr_offset(function, address, offset), result)
		}
		return result
	case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
		elem := types.get(store, resolved).elem
		stride, _, _ := types.layout(store, elem)
		if stride == 0 { return seed }
		return generated_hash_elements(state, elem, address, seed, size / stride, stride)
	case .Union:
		return generated_hash_union(state, resolved, address, seed)
	case .Any, .Slice, .Dynamic_Array, .Fixed_Capacity_Array, .Map:
		return generated_unsupported(state)
	}
	return generated_helper_call(state, "default_hasher_fixed", []ir.Node_Id{address, seed, ir.const_int(function, .I64, size)})
}

@(private = "file")
generated_equal_value :: proc(state: ^Procedure_State, type: types.Type_Id, left, right: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	resolved := types.resolve_named(store, type)
	size, _, _ := types.layout(store, resolved)
	kind := types.get(store, resolved).kind
	#partial switch kind {
	case .String:
		return generated_string_equal(state, left, right, 1)
	case .String16:
		return generated_string_equal(state, left, right, 2)
	case .CString:
		return generated_helper_call(state, "cstring_eq", []ir.Node_Id{lower_load_word(state, left, .Ptr), lower_load_word(state, right, .Ptr)})
	case .CString16:
		return generated_helper_call(state, "cstring16_eq", []ir.Node_Id{lower_load_word(state, left, .Ptr), lower_load_word(state, right, .Ptr)})
	case .Float:
		if size == 2 {
			left_wide := float16_widen(function, lower_load_word(state, left, .I16))
			right_wide := float16_widen(function, lower_load_word(state, right, .I16))
			return ir.compare(function, .FEq, left_wide, right_wide)
		}
		if size != 4 && size != 8 { return generated_unsupported(state) }
		return ir.compare(function, .FEq, lower_load(state, left, resolved), lower_load(state, right, resolved))
	case .Complex:
		return generated_equal_parts(state, left, right, size / 2, 2)
	case .Quaternion:
		return generated_equal_parts(state, left, right, size / 4, 4)
	case .Struct:
		fields := types.get(store, resolved).fields
		result := ir.const_int(function, .Bool, 1)
		for field, index in fields {
			offset, _ := types.field_offset(store, resolved, index)
			equal := generated_equal_value(state, field.type, ir.ptr_offset(function, left, offset), ir.ptr_offset(function, right, offset))
			result = ir.binary(function, .And, result, equal)
		}
		return result
	case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
		elem := types.get(store, resolved).elem
		stride, _, _ := types.layout(store, elem)
		if stride == 0 { return ir.const_int(function, .Bool, 1) }
		return generated_equal_elements(state, elem, left, right, size / stride, stride)
	case .Union:
		return generated_equal_union(state, resolved, left, right)
	case .Any, .Slice, .Dynamic_Array, .Fixed_Capacity_Array, .Map:
		return generated_unsupported(state)
	}
	if size == 0 { return ir.const_int(function, .Bool, 1) }
	return generated_helper_call(state, "memory_equal", []ir.Node_Id{left, right, ir.const_int(function, .I64, size)})
}

// Strings compare lengths first; a length mismatch makes the byte count zero, so memory_equal never reads past a string.
@(private = "file")
generated_string_equal :: proc(state: ^Procedure_State, left, right: ir.Node_Id, unit: i64) -> ir.Node_Id {
	function := state.job.function
	left_length := lower_load_word(state, ir.ptr_offset(function, left, 8), .I64)
	right_length := lower_load_word(state, ir.ptr_offset(function, right, 8), .I64)
	same := ir.compare(function, .Eq, left_length, right_length)
	count := ir.select(function, same, left_length, ir.const_int(function, .I64, 0))
	bytes := count
	if unit == 2 { bytes = ir.binary(function, .Shl, count, ir.const_int(function, .I64, 1)) }
	left_data := lower_load_word(state, left, .Ptr)
	right_data := lower_load_word(state, right, .Ptr)
	equal := generated_helper_call(state, "memory_equal", []ir.Node_Id{left_data, right_data, bytes})
	return ir.binary(function, .And, same, equal)
}

@(private = "file")
generated_equal_parts :: proc(state: ^Procedure_State, left, right: ir.Node_Id, part_size: i64, part_count: int) -> ir.Node_Id {
	function := state.job.function
	if part_size != 2 && part_size != 4 && part_size != 8 { return generated_unsupported(state) }
	part_type := ir.Value_Type.F64
	if part_size == 4 { part_type = .F32 }
	load_type := part_type
	if part_size == 2 { load_type = .I16 }
	result := ir.const_int(function, .Bool, 1)
	for index in 0 ..< part_count {
		offset := i64(index) * part_size
		left_value := lower_load_word(state, ir.ptr_offset(function, left, offset), load_type)
		right_value := lower_load_word(state, ir.ptr_offset(function, right, offset), load_type)
		if part_size == 2 {
			left_value = float16_widen(function, left_value)
			right_value = float16_widen(function, right_value)
		}
		equal := ir.compare(function, .FEq, left_value, right_value)
		result = ir.binary(function, .And, result, equal)
	}
	return result
}

@(private = "file")
generated_hash_parts :: proc(state: ^Procedure_State, address: ir.Node_Id, part_size: i64, part_count: int, seed: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	if part_size != 2 && part_size != 4 && part_size != 8 { return generated_unsupported(state) }
	part_type := ir.Value_Type.F64
	if part_size == 4 { part_type = .F32 }
	load_type := part_type
	if part_size == 2 { load_type = .I16 }
	result := seed
	for index in 0 ..< part_count {
		value := lower_load_word(state, ir.ptr_offset(function, address, i64(index) * part_size), load_type)
		if part_size == 2 { value = float16_widen(function, value) }
		if part_size != 8 { value = ir.convert(function, .Float_Ext, value, .F64) }
		result = generated_helper_call(state, "default_hasher_f64", []ir.Node_Id{value, result})
	}
	return result
}

@(private = "file")
generated_helper_call :: proc(state: ^Procedure_State, name: string, arguments: []ir.Node_Id) -> ir.Node_Id {
	program := state.job.program
	for entity in program.runtime.helper_entities {
		if program.entities[entity].name != name { continue }
		// An unresolved helper has no type or symbol; failing cleanly beats asserting in type lookup.
		if program.entities[entity].type == types.TYPE_NONE || program.entity_symbols[entity] == 0 { continue }
		symbol := state.job.symbols[program.entity_symbols[entity]]
		return generated_procedure_call(state, symbol, program.entities[entity].type, arguments)
	}
	return generated_unsupported(state)
}

@(private)
generated_procedure_call :: proc(state: ^Procedure_State, symbol: ir.Symbol_Ref, signature: types.Type_Id, arguments: []ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	allocator := virtual.arena_allocator(&function.arena)
	resolved := types.resolve_named(store, signature)
	descriptor := types.get(store, resolved)
	result_type := descriptor.results[0]
	planned := state.job.abi_plans.procedures[resolved]
	if !planned.valid { return generated_unsupported(state) }
	abi, abi_error := abi_signature(planned.plan, allocator)
	if abi_error != nil { return generated_unsupported(state) }
	id := ir.add_signature(function, abi)
	callee := ir.symbol_addr(function, symbol)
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, id, arguments)
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	value := ir.add_node(function, .Proj, abi.results[0].type, {call}, {index = 1})
	if types.get(store, result_type).kind == .Bool { value = ir.convert(function, .Trunc, value, .Bool) }
	return value
}

// Calls a runtime procedure whose result is two words, such as a 128-bit integer, and returns both pieces.
@(private)
lower_runtime_two_word_call :: proc(state: ^Procedure_State, declaration: Procedure_Declaration, arguments: []ir.Node_Id) -> (low, high: ir.Node_Id) {
	function := state.job.function
	callee := ir.symbol_addr(function, declaration.symbol)
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, call_signature(state, declaration), arguments)
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	low = ir.add_node(function, .Proj, declaration.signature.results[0].type, {call}, {index = 1})
	high = ir.add_node(function, .Proj, declaration.signature.results[1].type, {call}, {index = 2})
	return low, high
}

@(private = "file")
integer_value_type :: proc(size: i64) -> ir.Value_Type {
	switch size {
	case 1:
		return .I8
	case 2:
		return .I16
	case 4:
		return .I32
	}
	return .I64
}

@(private)
generated_union_tag :: proc(state: ^Procedure_State, address: ir.Node_Id, layout: types.Union_Layout) -> (tag: ir.Node_Id, tag_type: ir.Value_Type) {
	tag_type = integer_value_type(layout.tag_size)
	tag = lower_load_word(state, ir.ptr_offset(state.job.function, address, layout.variant_block_size), tag_type)
	return
}

// Tag values are variant index + 1, except for no_nil unions, which store the index (types.cpp union_variant_index_checked).
@(private = "file")
generated_union_tag_offset :: proc(form: types.Union_Form) -> i64 {
	return 0 if form == .No_Nil else 1
}

@(private = "file")
generated_hash_union :: proc(state: ^Procedure_State, union_type: types.Type_Id, address, seed: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	descriptor := types.get(store, union_type)
	form := descriptor.union_form
	variants := descriptor.variants
	if len(variants) == 0 { return seed }
	if form == .Maybe_Pointer { return generated_hash_value(state, variants[0], address, seed) }
	layout, layout_error := types.union_layout(store, union_type)
	if layout_error != .None || layout.tag_size == 0 { return generated_unsupported(state) }
	tag, tag_type := generated_union_tag(state, address, layout)
	tag_offset := generated_union_tag_offset(form)
	builder := state.builder
	result := ir.variable_declare(builder, seed)
	end := ir.jump_target_make(builder)
	for variant, index in variants {
		matched := ir.branch_if(builder, ir.compare(function, .Eq, tag, ir.const_int(function, tag_type, i64(index) + tag_offset)))
		ir.enter_arm(builder, matched, 0)
		ir.variable_set(builder, result, generated_hash_value(state, variant, address, seed))
		ir.jump_to(builder, end)
		ir.enter_arm(builder, matched, 1)
	}
	ir.jump_to(builder, end)
	ir.seal_target(builder, end)
	return ir.variable_get(builder, result)
}

@(private = "file")
generated_equal_union :: proc(state: ^Procedure_State, union_type: types.Type_Id, left, right: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	store := check.type_store(state.job.program)
	descriptor := types.get(store, union_type)
	form := descriptor.union_form
	variants := descriptor.variants
	if len(variants) == 0 { return ir.const_int(function, .Bool, 1) }
	if form == .Maybe_Pointer { return generated_equal_value(state, variants[0], left, right) }
	layout, layout_error := types.union_layout(store, union_type)
	if layout_error != .None || layout.tag_size == 0 { return generated_unsupported(state) }
	left_tag, tag_type := generated_union_tag(state, left, layout)
	right_tag := lower_load_word(state, ir.ptr_offset(function, right, layout.variant_block_size), tag_type)
	tag_offset := generated_union_tag_offset(form)
	builder := state.builder
	result := ir.variable_declare(builder, ir.const_int(function, .Bool, 0))
	end := ir.jump_target_make(builder)
	same := ir.branch_if(builder, ir.compare(function, .Eq, left_tag, right_tag))
	ir.enter_arm(builder, same, 0)
	ir.variable_set(builder, result, ir.const_int(function, .Bool, 1))
	for variant, index in variants {
		matched := ir.branch_if(builder, ir.compare(function, .Eq, left_tag, ir.const_int(function, tag_type, i64(index) + tag_offset)))
		ir.enter_arm(builder, matched, 0)
		ir.variable_set(builder, result, generated_equal_value(state, variant, left, right))
		ir.jump_to(builder, end)
		ir.enter_arm(builder, matched, 1)
	}
	ir.jump_to(builder, end)
	ir.enter_arm(builder, same, 1)
	ir.jump_to(builder, end)
	ir.seal_target(builder, end)
	return ir.variable_get(builder, result)
}

@(private = "file")
generated_hash_elements :: proc(state: ^Procedure_State, elem: types.Type_Id, address, seed: ir.Node_Id, count, stride: i64) -> ir.Node_Id {
	function := state.job.function
	builder := state.builder
	index := ir.variable_declare(builder, ir.const_int(function, .I64, 0))
	cursor := ir.variable_declare(builder, address)
	result := ir.variable_declare(builder, seed)
	end := ir.jump_target_make(builder)
	loop := ir.loop_begin(builder, []ir.Variable{index, cursor, result})
	branch := ir.branch_if(builder, ir.compare(function, .ULt, ir.variable_get(builder, index), ir.const_int(function, .I64, count)))
	ir.enter_arm(builder, branch, 1)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 0)
	hashed := generated_hash_value(state, elem, ir.variable_get(builder, cursor), ir.variable_get(builder, result))
	ir.variable_set(builder, result, hashed)
	ir.variable_set(builder, cursor, ir.ptr_offset(function, ir.variable_get(builder, cursor), stride))
	ir.variable_set(builder, index, ir.binary(function, .Add, ir.variable_get(builder, index), ir.const_int(function, .I64, 1)))
	ir.loop_end(builder, loop)
	ir.seal_target(builder, end)
	return ir.variable_get(builder, result)
}

@(private = "file")
generated_equal_elements :: proc(state: ^Procedure_State, elem: types.Type_Id, left, right: ir.Node_Id, count, stride: i64) -> ir.Node_Id {
	function := state.job.function
	builder := state.builder
	index := ir.variable_declare(builder, ir.const_int(function, .I64, 0))
	left_cursor := ir.variable_declare(builder, left)
	right_cursor := ir.variable_declare(builder, right)
	result := ir.variable_declare(builder, ir.const_int(function, .Bool, 1))
	end := ir.jump_target_make(builder)
	loop := ir.loop_begin(builder, []ir.Variable{index, left_cursor, right_cursor, result})
	branch := ir.branch_if(builder, ir.compare(function, .ULt, ir.variable_get(builder, index), ir.const_int(function, .I64, count)))
	ir.enter_arm(builder, branch, 1)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 0)
	equal := generated_equal_value(state, elem, ir.variable_get(builder, left_cursor), ir.variable_get(builder, right_cursor))
	ir.variable_set(builder, result, ir.binary(function, .And, ir.variable_get(builder, result), equal))
	ir.variable_set(builder, left_cursor, ir.ptr_offset(function, ir.variable_get(builder, left_cursor), stride))
	ir.variable_set(builder, right_cursor, ir.ptr_offset(function, ir.variable_get(builder, right_cursor), stride))
	ir.variable_set(builder, index, ir.binary(function, .Add, ir.variable_get(builder, index), ir.const_int(function, .I64, 1)))
	ir.loop_end(builder, loop)
	ir.seal_target(builder, end)
	return ir.variable_get(builder, result)
}

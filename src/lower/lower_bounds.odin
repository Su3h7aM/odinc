package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_check :: proc(state: ^Procedure_State, holds: ir.Node_Id) {
	branch := ir.branch_if(state.builder, holds)
	ir.enter_arm(state.builder, branch, 1)
	ir.emit_trap(state.builder)
	ir.enter_arm(state.builder, branch, 0)
}

@(private)
lower_bounds_check :: proc(state: ^Procedure_State, holds: ir.Node_Id, node: syntax.Node_Index, handler: string, bounds: []ir.Node_Id) {
	branch := ir.branch_if(state.builder, holds)
	ir.enter_arm(state.builder, branch, 1)
	if state.job.function.error == nil { state.job.function.nodes.flags[state.builder.control] += {.Cold} }
	lower_bounds_error(state, node, handler, bounds)
	ir.emit_unreachable(state.builder)
	ir.enter_arm(state.builder, branch, 0)
}

@(private)
lower_bounds_error :: proc(state: ^Procedure_State, node: syntax.Node_Index, handler: string, bounds: []ir.Node_Id) {
	with_context := state.context_pointer != 0
	name: string
	switch handler {
	case "bounds_check_error":
		name = "bounds_check_error_with_context" if with_context else "bounds_check_error_contextless"
	case "slice_expr_error_hi":
		name = "slice_expr_error_hi_with_context" if with_context else "slice_expr_error_hi_contextless"
	case "slice_expr_error_lo_hi":
		name = "slice_expr_error_lo_hi_with_context" if with_context else "slice_expr_error_lo_hi_contextless"
	case "multi_pointer_slice_expr_error":
		name = "multi_pointer_slice_expr_error_with_context" if with_context else "multi_pointer_slice_expr_error_contextless"
	case:
		lower_fail(state, node, .Bounds); return
	}
	declaration, found := lower_runtime_procedure(state, name)
	if !found { lower_fail(state, node, .Call); return }
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	arguments, err := make([]ir.Node_Id, len(declaration.signature.params), allocator)
	if err != nil { function.error = err; return }
	store := check.type_store(state.job.program)
	descriptor := types.get(store, types.resolve_named(store, declaration.type))
	file := state.job.program.files[state.job.procedure.body.file]
	position := state.ast.nodes[node].start
	if state.ast.nodes[node].kind == .Slice_Expr { position = state.ast.nodes[node].payload.(syntax.Slice_Expr).open }
	line, column := syntax.line_col(file.lines, position)
	values := [6]ir.Node_Id{}
	values[0] = lower_string(state, file.path)
	values[1] = ir.const_int(function, .I32, i64(line))
	values[2] = ir.const_int(function, .I32, i64(column))
	copy(values[3:], bounds)
	for value, index in values[:3 + len(bounds)] {
		first := source_index(declaration.abi_params, index)
		if first < 0 { lower_fail(state, node, .Call_Argument); return }
		span := parameter_span(declaration.abi_params[first:])
		if is_aggregate(state, descriptor.params[index]) {
			if !pass_aggregate_argument(state, value, descriptor.params[index], declaration.abi_params[first:first + span], arguments[first:first + span]) {
				lower_fail(state, node, .Call_Argument); return
			}
		} else {
			arguments[first] = value
		}
	}
	if declaration.signature.cc == .Odin { arguments[len(arguments) - 1] = state.context_pointer }
	if state.failed || function.error != nil { return }
	callee := ir.symbol_addr(function, declaration.symbol)
	call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, call_signature(state, declaration), arguments)
	memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
}

@(private)
lower_load_word :: proc(state: ^Procedure_State, address: ir.Node_Id, type: ir.Value_Type) -> ir.Node_Id {
	return ir.load(state.job.function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), address, type, 0)
}

@(private)
lower_store_word :: proc(state: ^Procedure_State, address, value: ir.Node_Id) {
	memory := ir.store(state.job.function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), address, value, 0)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
}

// Reads the data pointer and length from a slice, dynamic array or string header at `header`.
@(private)
lower_header_parts :: proc(state: ^Procedure_State, header: ir.Node_Id) -> (base, length: ir.Node_Id) {
	base = lower_load_word(state, header, .Ptr)
	length = lower_load_word(state, ir.ptr_offset(state.job.function, header, 8), .I64)
	return base, length
}

// An array is addressed directly; a slice's header holds the data pointer at 0 and the length at 8.
@(private)
lower_index_address :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Bounds_Plan) -> ir.Node_Id {
	ast_node := state.ast.nodes[node]
	if ast_node.kind != .Index_Expr { return lower_fail(state, node, .Place) }
	index := ast_node.payload.(syntax.Index_Expr)
	function := state.job.function
	base_type := lower_type(state, lower_info(state, index.expr).type)
	offset := lower_value(state, index.index)
	if state.failed { return 0 }
	if is_wide_integer(state, lower_info(state, index.index).type) {
		words := wide_load(state, offset)
		offset = words.low
	} else if function.nodes.type[offset] != .I64 {
		offset = ir.convert(function, .Sext if signed_type(state, lower_info(state, index.index).type) else .Zext, offset, .I64)
	}
	base_info := lower_info(state, index.expr)
	if base_info.plan != 0 {
		if swizzle, ok := check.plan(state.job.program, base_info.plan)^.(check.Swizzle_Plan); ok {
			backing := lower_swizzle_destination(state, swizzle, base_info.type)
			if plan.policy ==
			   .Enabled { lower_bounds_check(state, ir.compare(function, .ULt, offset, ir.const_int(function, .I64, i64(swizzle.count))), index.index, "bounds_check_error", {offset, ir.const_int(function, .I64, i64(swizzle.count))}) }
			table := ir.stack_slot(function, state.entry_control, u32(swizzle.count) * 8, 8)
			for lane in 0 ..< int(swizzle.count) { lower_store_word(state, ir.ptr_offset(function, table, i64(lane) * 8), backing.lanes[lane]) }
			return lower_load_word(state, ir.ptr_index(function, table, offset, 8), .Ptr)
		}
	}
	base, length: ir.Node_Id
	#partial switch base_type.kind {
	case .Array, .Enumerated_Array:
		base = lower_array_base(state, index.expr)
		length = ir.const_int(function, .I64, base_type.count)
		if base_type.kind == .Enumerated_Array {
			offset = ir.binary(function, .Sub, offset, ir.const_int(function, .I64, base_type.lower_bound))
		}
	case .Fixed_Capacity_Array:
		base = lower_array_base(state, index.expr)
		if state.failed || function.error != nil { return 0 }
		length = lower_fixed_capacity_length(state, base, base_type)
	case .Slice, .String, .String16, .Dynamic_Array:
		base, length = lower_header_parts(state, lower_value(state, index.expr))
	case .Multi_Pointer:
		base = lower_value(state, index.expr)
	case .Pointer:
		pointee := lower_type(state, base_type.elem)
		#partial switch pointee.kind {
		case .Array, .Enumerated_Array:
			base = lower_value(state, index.expr)
			length = ir.const_int(function, .I64, pointee.count)
			if pointee.kind == .Enumerated_Array {
				offset = ir.binary(function, .Sub, offset, ir.const_int(function, .I64, pointee.lower_bound))
			}
		case .Slice, .String, .String16, .Dynamic_Array:
			base, length = lower_header_parts(state, lower_value(state, index.expr))
		case:
			return lower_fail(state, node, .Place)
		}
	case:
		return lower_fail(state, node, .Place)
	}
	if state.failed || function.error != nil { return 0 }
	if plan.policy == .Enabled {
		holds := ir.compare(function, .ULt, offset, length)
		lower_bounds_check(state, holds, index.index, "bounds_check_error", {offset, length})
	}
	layout := state.job.layouts[lower_info(state, node).type]
	assert(layout.error == .None && layout.size <= i64(max(u32)))
	return ir.ptr_index(function, base, offset, u32(layout.size))
}

// A slice expression builds a new header in its own slot. Absent low and high bounds are nil operands.
@(private)
lower_slice_expression :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Bounds_Plan) -> ir.Node_Id {
	slice_node := node
	for state.ast.nodes[slice_node].kind == .Paren_Expr { slice_node = state.ast.nodes[slice_node].payload.(syntax.Paren_Expr).expr }
	ast_node := state.ast.nodes[slice_node]
	if ast_node.kind != .Slice_Expr { return lower_fail(state, node, .Place) }
	expression := ast_node.payload.(syntax.Slice_Expr)
	function := state.job.function
	base_type := lower_type(state, lower_info(state, expression.expr).type)
	base, length: ir.Node_Id
	element_size: i64
	#partial switch base_type.kind {
	case .Array:
		base = lower_address(state, expression.expr)
		length = ir.const_int(function, .I64, base_type.count)
		element_size = state.job.layouts[base_type.elem].size
	case .Slice, .Dynamic_Array:
		base, length = lower_header_parts(state, lower_value(state, expression.expr))
		element_size = state.job.layouts[base_type.elem].size
	case .Multi_Pointer:
		base = lower_value(state, expression.expr)
		element_size = state.job.layouts[base_type.elem].size
	case .String, .String16:
		header := lower_value(state, expression.expr)
		base = lower_load_word(state, header, .Ptr)
		length = lower_load_word(state, ir.ptr_offset(function, header, 8), .I64)
		element_size = 1 if base_type.kind == .String else 2
	case .Pointer:
		pointee := lower_type(state, base_type.elem)
		#partial switch pointee.kind {
		case .Array:
			base = lower_value(state, expression.expr)
			length = ir.const_int(function, .I64, pointee.count)
			element_size = state.job.layouts[pointee.elem].size
		case .Slice, .Dynamic_Array:
			base, length = lower_header_parts(state, lower_value(state, expression.expr))
			element_size = state.job.layouts[pointee.elem].size
		case .String, .String16:
			base, length = lower_header_parts(state, lower_value(state, expression.expr))
			element_size = 1 if pointee.kind == .String else 2
		case:
			return lower_fail(state, node, .Place)
		}
	case:
		return lower_fail(state, node, .Place)
	}
	low := lower_bound(state, plan.operands[1], ir.const_int(function, .I64, 0))
	assert(element_size <= i64(max(u32)))
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[low] != .I64 { return lower_fail(state, node, .Bounds) }
	if base_type.kind == .Multi_Pointer && plan.operands[2] == nil {
		return ir.ptr_index(function, base, low, u32(element_size))
	}
	high := lower_bound(state, plan.operands[2], length)
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[high] != .I64 { return lower_fail(state, node, .Bounds) }
	if plan.policy == .Enabled {
		handler := "slice_expr_error_lo_hi"
		bounds := []ir.Node_Id{low, high, length}
		holds := ir.compare(function, .ULe, low, high)
		if base_type.kind == .Multi_Pointer {
			handler = "multi_pointer_slice_expr_error"
			bounds = {low, high}
		} else {
			holds = ir.binary(function, .And, holds, ir.compare(function, .ULe, high, length))
			if expression.low == 0 { handler = "slice_expr_error_hi"; bounds = {high, length} }
		}
		lower_bounds_check(state, holds, slice_node, handler, bounds)
	}
	slot := ir.stack_slot(function, state.entry_control, 16, 8)
	lower_store_word(state, slot, ir.ptr_index(function, base, low, u32(element_size)))
	lower_store_word(state, ir.ptr_offset(function, slot, 8), ir.binary(function, .Sub, high, low))
	return slot
}

@(private)
lower_bound :: proc(state: ^Procedure_State, operand: check.Operand, default_value: ir.Node_Id) -> ir.Node_Id {
	if operand == nil { return default_value }
	function := state.job.function
	value := lower_operand(state, operand)
	if state.failed || function.error != nil || function.nodes.type[value] == .I64 || !is_integer_value(function, value) { return value }
	return ir.convert(function, .Sext if signed_type(state, operand_type(state, operand)) else .Zext, value, .I64)
}

// len of a slice or string reads the length word of its header.
@(private)
lower_length :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Builtin_Plan) -> ir.Node_Id {
	if value, handled := lower_soa_len_cap(state, node, info, plan, false); handled { return value }
	if len(plan.arguments) != 1 || scalar_type(state, info.type) != .I64 { return lower_fail(state, node, .Builtin) }
	argument_type := operand_type(state, plan.arguments[0])
	if lower_type(state, argument_type).kind == .CString {
		return lower_cstring_length(state, node, lower_operand(state, plan.arguments[0]))
	}
	header := lower_operand(state, plan.arguments[0])
	if state.failed || state.job.function.error != nil { return 0 }
	argument := lower_type(state, argument_type)
	if argument.kind == .Pointer { argument = lower_type(state, argument.elem) }
	if argument.kind == .Fixed_Capacity_Array { return lower_fixed_capacity_length(state, header, argument) }
	return lower_load_word(state, ir.ptr_offset(state.job.function, header, 8), .I64)
}

// The length word follows the element storage, rounded up to a word.
@(private)
lower_fixed_capacity_length :: proc(state: ^Procedure_State, address: ir.Node_Id, array: ^types.Type) -> ir.Node_Id {
	storage := state.job.layouts[array.elem].size * array.count
	return lower_load_word(state, ir.ptr_offset(state.job.function, address, (storage + 7) / 8 * 8), .I64)
}

lower_capacity :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Builtin_Plan) -> ir.Node_Id {
	if value, handled := lower_soa_len_cap(state, node, info, plan, true); handled { return value }
	if len(plan.arguments) != 1 || scalar_type(state, info.type) != .I64 { return lower_fail(state, node, .Builtin) }
	descriptor := lower_type(state, operand_type(state, plan.arguments[0]))
	if descriptor.kind == .Pointer { descriptor = lower_type(state, descriptor.elem) }
	if descriptor.kind == .Map {
		map_value := lower_operand(state, plan.arguments[0])
		if state.failed || state.job.function.error != nil { return 0 }
		return lower_map_runtime_call(state, node, "map_cap", []ir.Node_Id{map_value})
	}
	if descriptor.kind != .Dynamic_Array { return lower_fail(state, node, .Builtin) }
	header := lower_operand(state, plan.arguments[0])
	if state.failed || state.job.function.error != nil { return 0 }
	return lower_load_word(state, ir.ptr_offset(state.job.function, header, 16), .I64)
}

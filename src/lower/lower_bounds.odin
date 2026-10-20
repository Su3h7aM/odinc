package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

// Traps unless `holds`; execution continues in the arm where it holds.
@(private)
lower_check :: proc(state: ^Procedure_State, holds: ir.Node_Id) {
	branch := ir.branch_if(state.builder, holds)
	ir.enter_arm(state.builder, branch, 1)
	ir.emit_trap(state.builder)
	ir.enter_arm(state.builder, branch, 0)
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
	if function.nodes.type[offset] != .I64 {
		offset = ir.convert(function, .Sext if signed_type(state, lower_info(state, index.index).type) else .Zext, offset, .I64)
	}
	base_info := lower_info(state, index.expr)
	if base_info.plan != 0 {
		if swizzle, ok := check.plan(state.job.program, base_info.plan)^.(check.Swizzle_Plan); ok {
			backing := lower_swizzle_destination(state, swizzle, base_info.type)
			if plan.policy == .Enabled { lower_check(state, ir.compare(function, .ULt, offset, ir.const_int(function, .I64, i64(swizzle.count)))) }
			table := ir.stack_slot(function, state.entry_control, u32(swizzle.count) * 8, 8)
			for lane in 0 ..< int(swizzle.count) { lower_store_word(state, ir.ptr_offset(function, table, i64(lane) * 8), backing.lanes[lane]) }
			return lower_load_word(state, ir.ptr_index(function, table, offset, 8), .Ptr)
		}
	}
	base, length: ir.Node_Id
	#partial switch base_type.kind {
	case .Array:
		base = lower_array_base(state, index.expr)
		length = ir.const_int(function, .I64, base_type.count)
	case .Slice, .String, .String16, .Dynamic_Array:
		base, length = lower_header_parts(state, lower_value(state, index.expr))
	case .Multi_Pointer:
		base = lower_value(state, index.expr)
	case .Pointer:
		pointee := lower_type(state, base_type.elem)
		#partial switch pointee.kind {
		case .Array:
			base = lower_value(state, index.expr)
			length = ir.const_int(function, .I64, pointee.count)
		case .Slice, .String, .String16, .Dynamic_Array:
			base, length = lower_header_parts(state, lower_value(state, index.expr))
		case:
			return lower_fail(state, node, .Place)
		}
	case:
		return lower_fail(state, node, .Place)
	}
	if state.failed || function.error != nil { return 0 }
	if plan.policy == .Enabled { lower_check(state, ir.compare(function, .ULt, offset, length)) }
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
		if base_type.kind != .Multi_Pointer { lower_check(state, ir.compare(function, .ULe, high, length)) }
		lower_check(state, ir.compare(function, .ULe, low, high))
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
	if len(plan.arguments) != 1 || scalar_type(state, info.type) != .I64 { return lower_fail(state, node, .Builtin) }
	argument_type := operand_type(state, plan.arguments[0])
	if lower_type(state, argument_type).kind == .CString {
		return lower_cstring_length(state, node, lower_operand(state, plan.arguments[0]))
	}
	header := lower_operand(state, plan.arguments[0])
	if state.failed || state.job.function.error != nil { return 0 }
	return lower_load_word(state, ir.ptr_offset(state.job.function, header, 8), .I64)
}

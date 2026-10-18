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
	base, length: ir.Node_Id
	#partial switch base_type.kind {
	case .Array:
		base = lower_array_base(state, index.expr)
		length = ir.const_int(function, function.nodes.type[offset], base_type.count)
	case .Slice, .String, .String16:
		if function.nodes.type[offset] != .I64 { return lower_fail(state, node, .Bounds) }
		header := lower_value(state, index.expr)
		base = lower_load_word(state, header, .Ptr)
		length = lower_load_word(state, ir.ptr_offset(function, header, 8), .I64)
	case .Multi_Pointer:
		base = lower_value(state, index.expr)
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
	#partial switch base_type.kind {
	case .Array:
		base = lower_address(state, expression.expr)
		length = ir.const_int(function, .I64, base_type.count)
	case .Slice:
		header := lower_value(state, expression.expr)
		base = lower_load_word(state, header, .Ptr)
		length = lower_load_word(state, ir.ptr_offset(function, header, 8), .I64)
	case .Multi_Pointer:
		base = lower_value(state, expression.expr)
	case:
		return lower_fail(state, node, .Place)
	}
	low := lower_bound(state, plan.operands[1], ir.const_int(function, .I64, 0))
	layout := state.job.layouts[base_type.elem]
	assert(layout.error == .None && layout.size <= i64(max(u32)))
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[low] != .I64 { return lower_fail(state, node, .Bounds) }
	if base_type.kind == .Multi_Pointer && plan.operands[2] == nil {
		return ir.ptr_index(function, base, low, u32(layout.size))
	}
	high := lower_bound(state, plan.operands[2], length)
	if state.failed || function.error != nil { return 0 }
	if function.nodes.type[high] != .I64 { return lower_fail(state, node, .Bounds) }
	if plan.policy == .Enabled {
		if base_type.kind != .Multi_Pointer { lower_check(state, ir.compare(function, .ULe, high, length)) }
		lower_check(state, ir.compare(function, .ULe, low, high))
	}
	slot := ir.stack_slot(function, state.entry_control, 16, 8)
	lower_store_word(state, slot, ir.ptr_index(function, base, low, u32(layout.size)))
	lower_store_word(state, ir.ptr_offset(function, slot, 8), ir.binary(function, .Sub, high, low))
	return slot
}

@(private)
lower_bound :: proc(state: ^Procedure_State, operand: check.Operand, default_value: ir.Node_Id) -> ir.Node_Id {
	if operand == nil { return default_value }
	return lower_operand(state, operand)
}

// len of a slice or string reads the length word of its header.
@(private)
lower_length :: proc(state: ^Procedure_State, node: syntax.Node_Index, info: check.Expression_Info, plan: check.Builtin_Plan) -> ir.Node_Id {
	if len(plan.arguments) != 1 || scalar_type(state, info.type) != .I64 { return lower_fail(state, node, .Builtin) }
	header := lower_operand(state, plan.arguments[0])
	if state.failed || state.job.function.error != nil { return 0 }
	return lower_load_word(state, ir.ptr_offset(state.job.function, header, 8), .I64)
}

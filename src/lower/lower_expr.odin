package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_fail :: proc(state: ^Procedure_State, node: syntax.Node_Index, feature: Lower_Feature) -> ir.Node_Id {
	if !state.failed {
		report_procedure_error(state.job, .Unsupported, feature)
		if len(state.job.errors) > 0 {
			state.job.errors[len(state.job.errors) - 1].node = {state.job.procedure.body.file, node}
		}
		state.failed = true
	}
	return ir.NODE_NONE
}

@(private)
lower_info :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> check.Expression_Info {
	info, ok := check.expression_info(state.job.program, state.view, node)
	assert(ok && info.state == .Checked && (info.type != 0 || info.mode == .No_Value), "missing checked expression fact")
	return info
}

@(private)
lower_type :: proc(state: ^Procedure_State, id: types.Type_Id) -> ^types.Type {
	store := check.type_store(state.job.program)
	return types.get(store, types.resolve_named(store, id))
}

@(private)
signed_type :: proc(state: ^Procedure_State, id: types.Type_Id) -> bool {
	type := lower_type(state, id)
	if type.kind == .Enum || type.kind == .Bit_Field || type.kind == .Bit_Set && type.backing != 0 {
		return signed_type(state, type.backing)
	}
	return type.signed || type.kind == .Rune
}

@(private)
scalar_type :: proc(state: ^Procedure_State, id: types.Type_Id) -> ir.Value_Type {
	type := lower_type(state, id)
	#partial switch type.kind {
	case .Bool:
		return .Bool
	case .Rune:
		return .I32
	case .Integer:
		switch state.job.layouts[id].size {
		case 1:
			return .I8
		case 2:
			return .I16
		case 4:
			return .I32
		case 8:
			return .I64
		}
	case .Float:
		switch state.job.layouts[id].size {
		case 2:
			return .F16
		case 4:
			return .F32
		case 8:
			return .F64
		}
	case .Pointer, .Multi_Pointer, .Raw_Pointer, .CString, .CString16, .Procedure:
		return .Ptr
	case .Type_Id:
		return .I64
	case .Enum, .Bit_Field:
		return scalar_type(state, type.backing)
	case .Bit_Set:
		if type.backing != 0 { return scalar_type(state, type.backing) }
		layout := state.job.layouts[id]
		switch layout.size {
		case 1:
			return .I8
		case 2:
			return .I16
		case 4:
			return .I32
		case 8:
			return .I64
		}
	}
	return .None
}

@(private)
operand_type :: proc(state: ^Procedure_State, operand: check.Operand) -> types.Type_Id {
	switch value in operand {
	case check.Expression_Ref:
		info, ok := check.expression_info(state.job.program, value.view, value.node)
		assert(ok)
		return info.type
	case check.Entity_Id:
		return state.job.program.entities[value].type
	case check.Const_Id:
		return check.constant(state.job.program, value).type
	case check.Projection:
		lower_fail(state, value.expression.node, .Expression)
	}
	return 0
}

@(private)
lower_operand :: proc(state: ^Procedure_State, operand: check.Operand, target := types.Type_Id(0)) -> ir.Node_Id {
	if state.failed { return 0 }
	switch value in operand {
	case check.Expression_Ref:
		previous_view := state.view
		state.view = value.view
		defer state.view = previous_view
		if target != 0 {
			info := lower_info(state, value.node)
			if info.constant != 0 { return lower_constant(state, info.constant, target) }
		}
		return lower_value(state, value.node)
	case check.Const_Id:
		return lower_constant(state, value, target)
	case check.Entity_Id:
		return lower_entity_value(state, value)
	case check.Projection:
		return lower_fail(state, value.expression.node, .Expression)
	}
	return 0
}

@(private)
lower_entity_value :: proc(state: ^Procedure_State, entity: check.Entity_Id) -> ir.Node_Id {
	assert(entity != 0)
	binding := state.locals[entity]
	if binding.kind == .Variable { return ir.variable_get(state.builder, binding.variable) }
	if binding.kind == .Address { return lower_load(state, binding.address, state.job.program.entities[entity].type) }
	constant := state.job.program.entities[entity].constant
	if constant != 0 { return lower_constant(state, constant, state.job.program.entities[entity].type) }
	symbol := check.entity_symbol(state.job.program, entity)
	if symbol != 0 {
		ref := state.job.symbols[symbol]
		if ref.space == .Function || ref.space == .Extern { return ir.symbol_addr(state.job.function, ref) }
		address: ir.Node_Id
		if check.symbols(state.job.program)[int(symbol) - 1].thread_local {
			address = ir.tls_addr(state.job.function, ref)
		} else {
			address = ir.symbol_addr(state.job.function, ref)
		}
		return lower_load(state, address, state.job.program.entities[entity].type)
	}
	return lower_fail(state, state.job.procedure.body.node, .Local)
}

// The checker marks the branch not taken as Inactive; lowering takes the other one.
@(private)
lower_ternary_when_branch :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> syntax.Node_Index {
	ternary := state.ast.nodes[node].payload.(syntax.Ternary_Expr)
	info, _ := check.expression_info(state.job.program, state.view, ternary.x)
	if info.state == .Inactive { return ternary.y }
	return ternary.x
}

@(private)
lower_value :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	if state.ast.nodes[node].kind == .Ternary_When_Expr { return lower_value(state, lower_ternary_when_branch(state, node)) }
	if state.ast.nodes[node].kind == .Paren_Expr { return lower_value(state, state.ast.nodes[node].payload.(syntax.Paren_Expr).expr) }
	if state.ast.nodes[node].kind == .Ternary_If_Expr { return lower_ternary_if(state, node) }
	info := lower_info(state, node)
	if info.constant != 0 { return lower_constant(state, info.constant, info.type) }
	if info.plan != 0 {
		plan := check.plan(state.job.program, info.plan)
		if plan == nil &&
		   (state.ast.nodes[node].kind == .Call_Expr || state.ast.nodes[node].kind == .Selector_Call_Expr) { return lower_fail(state, node, .Call) }
		assert(plan != nil)
		#partial switch value in plan^ {
		case check.Conversion_Plan:
			return lower_conversion(state, value, node)
		case check.Place_Plan:
			return lower_load(state, lower_place(state, value, node), info.type)
		case check.Aggregate_Plan:
			return lower_aggregate(state, node, value)
		case check.Bounds_Plan:
			if value.kind == .Slice { return lower_slice_expression(state, node, value) }
			return lower_load(state, lower_index_address(state, node, value), info.type)
		case check.Call_Plan:
			return lower_call(state, node, info, value)
		case check.Builtin_Plan:
			return lower_builtin(state, node, info, value)
		case check.Typeid_Plan:
			return lower_typeid(state, node, value)
		case check.Type_Info_Plan:
			return lower_type_info_of(state, node, value)
		case check.Propagation_Plan:
			if state.ast.nodes[node].kind == .Or_Return_Expr { return lower_or_return(state, node, value) }
			if state.ast.nodes[node].kind == .Or_Branch_Expr { return lower_or_branch(state, node, value) }
			return lower_or_else(state, node, value)
		case:
			return lower_fail(state, node, .Expression)
		}
	}
	ast_node := state.ast.nodes[node]
	#partial switch ast_node.kind {
	case .Implicit:
		return state.context_pointer
	case .Ident:
		assert(info.entity != 0)
		return lower_entity_value(state, info.entity)
	case .Call_Expr, .Selector_Call_Expr:
		return lower_fail(state, node, .Call)
	case .Paren_Expr:
		return lower_value(state, ast_node.payload.(syntax.Paren_Expr).expr)
	case .Unary_Expr:
		value := ast_node.payload.(syntax.Unary_Expr)
		if value.op.kind == .And { return lower_address(state, value.expr) }
		operand := lower_value(state, value.expr)
		if state.failed { return 0 }
		function := state.job.function
		if is_wide_integer(state, lower_info(state, value.expr).type) { return lower_wide_unary(state, node, value.op.kind, operand) }
		if scalar_type(state, lower_info(state, value.expr).type) == .None { return lower_fail(state, node, .Operator) }
		if function.nodes.type[operand] == .F16 {
			if value.op.kind == .Sub { return float16_negate(function, operand) }
			return lower_fail(state, node, .Operator)
		}
		#partial switch value.op.kind {
		case .Add:
			return operand
		case .Sub:
			if lower_type(state, info.type).kind == .Float { return ir.unary(function, .FNeg, operand) }
			return ir.binary(function, .Sub, ir.const_int(function, scalar_type(state, info.type), 0), operand)
		case .Xor:
			return ir.binary(function, .Xor, operand, ir.const_int(function, scalar_type(state, info.type), -1))
		case .Not:
			return ir.binary(function, .Xor, operand, ir.const_int(function, .Bool, 1))
		}
	case .Binary_Expr:
		value := ast_node.payload.(syntax.Binary_Expr)
		return lower_binary(state, node, value)
	case .Deref_Expr, .Index_Expr, .Selector_Expr:
		return lower_load(state, lower_address(state, node), info.type)
	case .Undef:
		scalar := scalar_type(state, info.type)
		if scalar == .None { return lower_fail(state, node, .Constant) }
		return ir.undef(state.job.function, scalar)
	}
	return lower_fail(state, node, .Expression)
}

@(private)
lower_load :: proc(state: ^Procedure_State, address: ir.Node_Id, type: types.Type_Id) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	scalar := scalar_type(state, type)
	if scalar == .None { return address }
	if scalar == .Bool {
		function := state.job.function
		byte := ir.load(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), address, .I8, 0)
		return ir.convert(function, .Trunc, byte, .Bool)
	}
	value := ir.load(state.job.function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), address, scalar, 0)
	return lower_endian_value(state, value, type)
}

@(private)
lower_address :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> ir.Node_Id {
	if state.failed { return 0 }
	if state.ast.nodes[node].kind == .Paren_Expr { return lower_address(state, state.ast.nodes[node].payload.(syntax.Paren_Expr).expr) }
	info := lower_info(state, node)
	if info.plan != 0 {
		plan := check.plan(state.job.program, info.plan)
		assert(plan != nil)
		#partial switch value in plan^ {
		case check.Place_Plan:
			return lower_place(state, value, node)
		case check.Bounds_Plan:
			if value.kind != .Index { return lower_fail(state, node, .Place) }
			return lower_index_address(state, node, value)
		case:
			return lower_fail(state, node, .Place)
		}
	}
	ast_node := state.ast.nodes[node]
	#partial switch ast_node.kind {
	case .Implicit:
		return state.context_pointer
	case .Ident:
		binding := state.locals[info.entity]
		if binding.kind == .Address { return binding.address }
		symbol := check.entity_symbol(state.job.program, info.entity)
		if symbol != 0 {
			ref := state.job.symbols[symbol]
			if check.symbols(state.job.program)[int(symbol) - 1].thread_local { return ir.tls_addr(state.job.function, ref) }
			return ir.symbol_addr(state.job.function, ref)
		}
		assert(binding.kind != .Variable, "address-taken pre-pass missed a local")
	case .Paren_Expr:
		return lower_address(state, ast_node.payload.(syntax.Paren_Expr).expr)
	case .Deref_Expr:
		return lower_value(state, ast_node.payload.(syntax.Deref_Expr).expr)
	}
	return lower_fail(state, node, .Place)
}

@(private)
lower_operand_address :: proc(state: ^Procedure_State, operand: check.Operand) -> ir.Node_Id {
	#partial switch value in operand {
	case check.Entity_Id:
		binding := state.locals[value]
		if binding.kind == .Address { return binding.address }
		symbol := check.entity_symbol(state.job.program, value)
		if symbol != 0 {
			ref := state.job.symbols[symbol]
			if check.symbols(state.job.program)[int(symbol) - 1].thread_local { return ir.tls_addr(state.job.function, ref) }
			return ir.symbol_addr(state.job.function, ref)
		}
	case check.Expression_Ref:
		previous_view := state.view
		state.view = value.view
		defer state.view = previous_view
		return lower_address(state, value.node)
	case:
	}
	return lower_fail(state, state.job.procedure.body.node, .Place)
}

@(private)
lower_place :: proc(state: ^Procedure_State, plan: check.Place_Plan, node: syntax.Node_Index) -> ir.Node_Id {
	if plan.bit_size != 0 { return lower_fail(state, node, .Place) }
	if len(plan.path) == 0 { return lower_operand_address(state, plan.root) }
	base := lower_operand(state, plan.root)
	if state.failed { return 0 }
	total: i64
	for step in plan.path {
		offset, err := types.field_offset(check.type_store(state.job.program), step.type, int(step.field_index))
		if err != .None { return lower_fail(state, node, .Place) }
		total += i64(offset)
	}
	return ir.ptr_offset(state.job.function, base, total)
}

@(private)
lower_store :: proc(state: ^Procedure_State, address, value: ir.Node_Id, type: types.Type_Id) {
	if state.failed || state.job.function.error != nil { return }
	function := state.job.function
	memory := ir.variable_get(state.builder, ir.MEMORY_VARIABLE)
	if scalar_type(state, type) != .None {
		stored_value := lower_endian_value(state, value, type)
		if function.nodes.type[stored_value] == .Bool { stored_value = ir.convert(function, .Zext, stored_value, .I8) }
		memory = ir.store(function, state.builder.control, memory, address, stored_value, 0)
	} else {
		size := ir.const_int(function, .I64, state.job.layouts[type].size)
		memory = ir.add_node(function, .Mem_Copy, .Memory, {state.builder.control, memory, address, value, size})
	}
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
}

@(private)
lower_endian_value :: proc(state: ^Procedure_State, value: ir.Node_Id, type: types.Type_Id) -> ir.Node_Id {
	if state.job.function.error != nil { return 0 }
	descriptor := lower_type(state, type)
	if descriptor.kind == .Enum || descriptor.kind == .Bit_Field || descriptor.kind == .Bit_Set && descriptor.backing != 0 {
		return lower_endian_value(state, value, descriptor.backing)
	}
	if descriptor.endianness != .Big { return value }
	function := state.job.function
	scalar := function.nodes.type[value]
	integer := scalar
	#partial switch scalar {
	case .F16:
		integer = .I16
	case .F32:
		integer = .I32
	case .F64:
		integer = .I64
	}
	if integer != .I16 && integer != .I32 && integer != .I64 { return value }
	result := value
	if scalar != integer { result = ir.convert(function, .Bitcast, result, integer) }
	result = ir.unary(function, .Bswap, result)
	if scalar != integer { result = ir.convert(function, .Bitcast, result, scalar) }
	return result
}

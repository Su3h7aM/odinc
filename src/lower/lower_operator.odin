package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
lower_binary :: proc(state: ^Procedure_State, node: syntax.Node_Index, expression: syntax.Binary_Expr) -> ir.Node_Id {
	left := lower_value(state, expression.left)
	if state.failed { return 0 }
	if expression.op.kind == .Cmp_And || expression.op.kind == .Cmp_Or {
		return lower_short_circuit(state, node, expression, left)
	}
	right := lower_value(state, expression.right)
	if state.failed { return 0 }
	if is_wide_integer(state, lower_info(state, expression.left).type) { return lower_wide_binary(state, node, expression, left, right) }
	function := state.job.function
	type := function.nodes.type[left]
	signed := signed_type(state, lower_info(state, expression.left).type)
	if scalar_type(state, lower_info(state, expression.left).type) == .None { return lower_fail(state, node, .Operator) }
	floating := type == .F32 || type == .F64
	if type == .F16 || type == .V128 { return lower_fail(state, node, .Operator) }
	#partial switch expression.op.kind {
	case .Add:
		return ir.binary(function, .FAdd if floating else .Add, left, right)
	case .Sub:
		return ir.binary(function, .FSub if floating else .Sub, left, right)
	case .Mul:
		return ir.binary(function, .FMul if floating else .Mul, left, right)
	case .And:
		return ir.binary(function, .And, left, right)
	case .Or:
		return ir.binary(function, .Or, left, right)
	case .Xor:
		return ir.binary(function, .Xor, left, right)
	case .And_Not:
		return ir.binary(function, .And, left, ir.binary(function, .Xor, right, ir.const_int(function, type, -1)))
	case .Shl:
		return ir.binary(function, .Shl, left, right)
	case .Shr:
		return ir.binary(function, .Sar if signed else .Shr, left, right)
	case .Quo:
		if floating { return ir.binary(function, .FDiv, left, right) }
		return lower_integer_division(state, node, expression.op.kind, signed, left, right)
	case .Mod, .Mod_Mod:
		if floating { return lower_fail(state, node, .Operator) }
		return lower_integer_division(state, node, expression.op.kind, signed, left, right)
	case .Cmp_Eq:
		return ir.compare(function, .FEq if floating else .Eq, left, right)
	case .Not_Eq:
		return ir.compare(function, .FNe if floating else .Ne, left, right)
	case .Lt, .Gt:
		kind := ir.Node_Kind.FLt if floating else (ir.Node_Kind.SLt if signed else ir.Node_Kind.ULt)
		if expression.op.kind == .Gt { left, right = right, left }
		return ir.compare(function, kind, left, right)
	case .Lt_Eq, .Gt_Eq:
		kind := ir.Node_Kind.FLe if floating else (ir.Node_Kind.SLe if signed else ir.Node_Kind.ULe)
		if expression.op.kind == .Gt_Eq { left, right = right, left }
		return ir.compare(function, kind, left, right)
	}
	return lower_fail(state, node, .Operator)
}

@(private)
lower_short_circuit :: proc(state: ^Procedure_State, node: syntax.Node_Index, expression: syntax.Binary_Expr, left: ir.Node_Id) -> ir.Node_Id {
	builder := state.builder
	count := len(builder.values)
	result := ir.variable_declare(builder, left)
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, left)
	short_arm := 0 if expression.op.kind == .Cmp_Or else 1
	ir.enter_arm(builder, branch, short_arm)
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1 - short_arm)
	value := lower_value(state, expression.right)
	if state.failed { return 0 }
	ir.variable_set(builder, result, value)
	ir.jump_to(builder, end)
	ir.seal_target(builder, end)
	value = ir.variable_get(builder, result)
	ir.variables_truncate(builder, count)
	return value
}

@(private)
lower_integer_division :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	signed: bool,
	left, right: ir.Node_Id,
) -> ir.Node_Id {
	function := state.job.function
	if function.nodes.kind[right] == .Const_Int && ir.node_int_value(function, right) != 0 {
		return lower_nonzero_division(state, operator, signed, left, right)
	}
	mode := check.sources(state.job.program)[int(state.job.procedure.body.file) - 1].policy.division_by_zero
	assert(mode != .Unspecified, "checker must resolve integer division policy")
	builder := state.builder
	type := function.nodes.type[left]
	count := len(builder.values)
	result := ir.variable_declare(builder, ir.undef(function, type))
	end := ir.jump_target_make(builder)
	branch := ir.branch_if(builder, ir.compare(function, .Ne, right, ir.const_int(function, type, 0)))
	ir.enter_arm(builder, branch, 0)
	ir.variable_set(builder, result, lower_nonzero_division(state, operator, signed, left, right))
	ir.jump_to(builder, end)
	ir.enter_arm(builder, branch, 1)
	if mode == .Trap {
		ir.emit_trap(builder)
	} else {
		value: ir.Node_Id
		if operator == .Quo {
			#partial switch mode {
			case .Zero:
				value = ir.const_int(function, type, 0)
			case .Self:
				value = left
			case .All_Bits:
				value = ir.const_int(function, type, -1)
			case:
				unreachable()
			}
		} else {
			value = ir.const_int(function, type, 0) if mode == .Self else left
		}
		ir.variable_set(builder, result, value)
		ir.jump_to(builder, end)
	}
	ir.seal_target(builder, end)
	value := ir.variable_get(builder, result)
	ir.variables_truncate(builder, count)
	return value
}

@(private)
lower_nonzero_division :: proc(state: ^Procedure_State, operator: syntax.Token_Kind, signed: bool, left, right: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	if operator == .Quo {
		return ir.divide(function, .SDiv if signed else .UDiv, state.builder.control, left, right)
	}
	if !signed { return ir.divide(function, .URem, state.builder.control, left, right) }
	type := function.nodes.type[right]
	zero := ir.const_int(function, type, 0)
	minus_one := ir.const_int(function, type, -1)
	safe_divisor := ir.select(function, ir.compare(function, .Eq, right, minus_one), ir.const_int(function, type, 1), right)
	remainder := ir.divide(function, .SRem, state.builder.control, left, safe_divisor)
	if operator != .Mod_Mod { return remainder }
	different_signs := ir.compare(function, .SLt, ir.binary(function, .Xor, left, right), zero)
	nonzero := ir.compare(function, .Ne, remainder, zero)
	adjust := ir.binary(function, .And, different_signs, nonzero)
	return ir.select(function, adjust, ir.binary(function, .Add, remainder, right), remainder)
}

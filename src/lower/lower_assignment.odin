package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_compound_assignment :: proc(state: ^Procedure_State, node: syntax.Node_Index, assignment: syntax.Assign_Stmt) {
	left := syntax.node_list(state.ast, assignment.lhs)
	right := syntax.node_list(state.ast, assignment.rhs)
	if len(left) != 1 || len(right) != 1 { lower_fail(state, node, .Local); return }
	if assignment.op.kind == .Cmp_And_Eq || assignment.op.kind == .Cmp_Or_Eq { lower_fail(state, node, .Control); return }
	info, ok := check.expression_info(state.job.program, state.view, node)
	destination: Assignment_Destination
	value: ir.Node_Id
	if ok && info.plan != 0 {
		plan := check.plan(state.job.program, info.plan)
		assert(plan != nil)
		checked, found := plan^.(check.Assignment_Plan)
		if !found || len(checked.destinations) != 1 || len(checked.values) != 1 { lower_fail(state, node, .Local); return }
		destination = lower_destination(state, checked.destinations[0])
		if len(checked.conversions) != 0 && checked.conversions[0] != 0 {
			conversion := check.plan(state.job.program, checked.conversions[0])
			assert(conversion != nil)
			converted, found_conversion := conversion^.(check.Conversion_Plan)
			if !found_conversion { lower_fail(state, node, .Conversion); return }
			value = lower_conversion(state, converted, node)
		} else {
			value = lower_operand(state, checked.values[0], destination.type)
		}
	} else {
		destination = lower_destination(state, check.Expression_Ref{state.view, left[0]})
		value = lower_value(state, right[0])
	}
	if state.failed || state.job.function.error != nil { return }
	if destination.type == 0 { lower_fail(state, node, .Local); return }
	previous :=
		ir.variable_get(state.builder, state.locals[destination.entity].variable) if destination.entity != 0 else lower_load(state, destination.address, destination.type)
	result := lower_compound_operator(state, node, assignment.op.kind, previous, value, destination.type)
	write_destination(state, destination, result, node)
}

@(private)
lower_compound_operator :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	operator: syntax.Token_Kind,
	left, right: ir.Node_Id,
	type: types.Type_Id,
) -> ir.Node_Id {
	function := state.job.function
	scalar := scalar_type(state, type)
	if scalar == .None || scalar == .F16 || scalar == .Ptr { return lower_fail(state, node, .Operator) }
	if operator != .Shl_Eq && operator != .Shr_Eq && function.nodes.type[left] != function.nodes.type[right] { return lower_fail(state, node, .Conversion) }
	floating := scalar == .F32 || scalar == .F64
	#partial switch operator {
	case .Add_Eq:
		return ir.binary(function, .FAdd if floating else .Add, left, right)
	case .Sub_Eq:
		return ir.binary(function, .FSub if floating else .Sub, left, right)
	case .Mul_Eq:
		return ir.binary(function, .FMul if floating else .Mul, left, right)
	case .Quo_Eq:
		if floating { return ir.binary(function, .FDiv, left, right) }
		return lower_integer_division(state, node, .Quo, signed_type(state, type), left, right)
	case .Mod_Eq, .Mod_Mod_Eq:
		if floating { return lower_fail(state, node, .Operator) }
		operation := syntax.Token_Kind.Mod if operator == .Mod_Eq else syntax.Token_Kind.Mod_Mod
		return lower_integer_division(state, node, operation, signed_type(state, type), left, right)
	case .And_Eq:
		return ir.binary(function, .And, left, right)
	case .Or_Eq:
		return ir.binary(function, .Or, left, right)
	case .Xor_Eq:
		return ir.binary(function, .Xor, left, right)
	case .And_Not_Eq:
		return ir.binary(function, .And, left, ir.binary(function, .Xor, right, ir.const_int(function, scalar, -1)))
	case .Shl_Eq:
		return ir.binary(function, .Shl, left, right)
	case .Shr_Eq:
		return ir.binary(function, .Sar if signed_type(state, type) else .Shr, left, right)
	}
	return lower_fail(state, node, .Operator)
}

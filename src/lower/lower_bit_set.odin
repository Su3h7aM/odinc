package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
lower_bit_set_literal :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Bit_Set_Literal_Plan) -> ir.Node_Id {
	function := state.job.function
	descriptor := lower_type(state, plan.type)
	wide := is_wide_integer(state, plan.type)
	scalar := scalar_type(state, plan.type)
	if !wide && scalar == .None { return lower_fail(state, node, .Expression) }
	zero := ir.const_int(function, .I64, 0)
	words := Wide_Words {
		low  = zero,
		high = zero,
	}
	result := zero
	if !wide { result = ir.const_int(function, scalar, 0) }
	for operand in plan.values {
		index := lower_bound(state, operand, zero)
		if state.failed { return 0 }
		index = ir.binary(function, .Sub, index, ir.const_int(function, .I64, descriptor.lower_bound))
		if wide {
			bit := wide_shift(function, .Shl, Wide_Words{low = ir.const_int(function, .I64, 1), high = zero}, index)
			words = wide_bitwise(function, .Or, words, bit)
		} else {
			bit := ir.binary(function, .Shl, ir.const_int(function, scalar, 1), index)
			result = ir.binary(function, .Or, result, bit)
		}
	}
	if wide { return wide_store(state, words) }
	return result
}

@(private)
lower_bit_set_operator :: proc(state: ^Procedure_State, node: syntax.Node_Index, operator: syntax.Token_Kind, left, right: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	scalar := function.nodes.type[left]
	#partial switch operator {
	case .Add, .Or:
		return ir.binary(function, .Or, left, right)
	case .Sub, .And_Not:
		return ir.binary(function, .And, left, ir.binary(function, .Xor, right, ir.const_int(function, scalar, -1)))
	case .And:
		return ir.binary(function, .And, left, right)
	case .Xor:
		return ir.binary(function, .Xor, left, right)
	case .Cmp_Eq:
		return ir.compare(function, .Eq, left, right)
	case .Not_Eq:
		return ir.compare(function, .Ne, left, right)
	case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		subset_left, subset_right := left, right
		if operator == .Gt || operator == .Gt_Eq { subset_left, subset_right = right, left }
		difference := ir.binary(function, .And, subset_left, ir.binary(function, .Xor, subset_right, ir.const_int(function, scalar, -1)))
		subset := ir.compare(function, .Eq, difference, ir.const_int(function, scalar, 0))
		if operator == .Lt || operator == .Gt {
			return ir.binary(function, .And, subset, ir.compare(function, .Ne, left, right))
		}
		return subset
	}
	return lower_fail(state, node, .Operator)
}

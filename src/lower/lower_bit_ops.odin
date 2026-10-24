package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
lower_saturating :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	storage: [4]ir.Node_Id
	values, ok := lower_intrinsic_operands(state, node, plan, storage[:])
	if !ok { return 0 }
	function := state.job.function
	type := scalar_type(state, info.type)
	if !is_integer_type(type) || function.nodes.type[values[0]] != type || function.nodes.type[values[1]] != type { return lower_fail(state, node, .Builtin) }
	return saturating_value(state, kind == .Saturating_Add, signed_type(state, info.type), values[0], values[1])
}

// The sum or difference clamped to the range of the integer type of `left`.
@(private)
saturating_value :: proc(state: ^Procedure_State, is_add, signed: bool, left, right: ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	type := function.nodes.type[left]
	operation := check.Builtin_Kind.Overflow_Add if is_add else check.Builtin_Kind.Overflow_Sub
	value, overflow := lower_overflow(state, operation, signed, left, right)
	bits := scalar_bits(type)
	maximum := i64((u64(1) << uint(bits - 1)) - 1) if signed else i64(-1)
	limit := ir.const_int(function, type, maximum)
	if signed {
		negative := ir.compare(function, .SLt, left, ir.const_int(function, type, 0))
		minimum := ir.const_int(function, type, i64(u64(1) << uint(bits - 1)))
		limit = ir.add_node(function, .Select, type, {negative, minimum, limit})
	} else if !is_add { limit = ir.const_int(function, type, 0) }
	return ir.add_node(function, .Select, type, {overflow, limit, value})
}

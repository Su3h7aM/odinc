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
	values, ok := lower_intrinsic_operands(state, node, plan)
	if !ok { return 0 }
	function := state.job.function
	type := scalar_type(state, info.type)
	if !is_integer_type(type) || function.nodes.type[values[0]] != type || function.nodes.type[values[1]] != type { return lower_fail(state, node, .Builtin) }
	signed := signed_type(state, info.type)
	operation := check.Builtin_Kind.Overflow_Add if kind == .Saturating_Add else check.Builtin_Kind.Overflow_Sub
	value, overflow := lower_overflow(state, operation, signed, values[0], values[1])
	bits := scalar_bits(type)
	maximum := i64((u64(1) << uint(bits - 1)) - 1) if signed else i64(-1)
	limit := ir.const_int(function, type, maximum)
	if signed {
		negative := ir.compare(function, .SLt, values[0], ir.const_int(function, type, 0))
		minimum := ir.const_int(function, type, i64(u64(1) << uint(bits - 1)))
		limit = ir.add_node(function, .Select, type, {negative, minimum, limit})
	} else if kind == .Saturating_Sub { limit = ir.const_int(function, type, 0) }
	return ir.add_node(function, .Select, type, {overflow, limit, value})
}

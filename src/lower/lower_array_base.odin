package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

// An array value that is not a variable (a literal, constant or call result) already lives in memory, so the
// address lower_value returns is the base; it is evaluated once.
@(private)
lower_array_base :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> ir.Node_Id {
	info := lower_info(state, node)
	if info.mode == check.Addressing_Mode.Variable {
		if info.plan != 0 {
			if _, is_swizzle := check.plan(state.job.program, info.plan)^.(check.Swizzle_Plan); is_swizzle {
				// A swizzle names lanes, not storage; iterate a gathered copy.
				return lower_value(state, node)
			}
		}
		return lower_address(state, node)
	}
	return lower_value(state, node)
}

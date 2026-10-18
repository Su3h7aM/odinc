package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

// An array value that is not a variable (a literal, constant or call result) already lives in memory, so the
// address lower_value returns is the base; it is evaluated once.
@(private)
lower_array_base :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> ir.Node_Id {
	if lower_info(state, node).mode == check.Addressing_Mode.Variable { return lower_address(state, node) }
	return lower_value(state, node)
}

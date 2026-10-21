package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

// Address of the hasher the checker generated for the planned type, the same procedure map keys of that type use.
@(private)
lower_type_hasher_proc :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Builtin_Plan) -> ir.Node_Id {
	for procedure in check.procedures(state.job.program) {
		if procedure.generated == (check.Generated_Body{kind = .Hasher, type = plan.type}) {
			return ir.symbol_addr(state.job.function, state.job.symbols[procedure.symbol])
		}
	}
	return lower_fail(state, node, .Builtin)
}

package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// The callee of a call through a procedure-typed field. A `base->field(...)` call names the owner of the field once: the
// owner's address is returned with the callee, and the receiver argument passes that same address.
@(private)
lower_callee_value :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Call_Plan) -> (callee, owner: ir.Node_Id) {
	if len(plan.arguments) == 0 || plan.arguments[0].receiver == .None { return lower_operand(state, plan.callee), 0 }
	selector, is_ref := plan.callee.(check.Expression_Ref)
	if !is_ref { lower_fail(state, node, .Call_Argument); return 0, 0 }
	place, base, is_place := lower_selector_place(state, selector)
	if !is_place { lower_fail(state, node, .Call_Argument); return 0, 0 }
	owner = lower_selector_owner_address(state, base, place.path[:len(place.path) - 1])
	if state.failed { return 0, 0 }
	last := place.path[len(place.path) - 1]
	offset, err := types.field_offset(check.type_store(state.job.program), last.type, int(last.field_index))
	if err != .None { lower_fail(state, node, .Place); return 0, 0 }
	info := lower_info(state, selector.node)
	field_address := ir.ptr_offset(state.job.function, owner, i64(offset))
	return lower_load(state, field_address, info.type), owner
}

// The receiver of `base->field(...)`: the object owning the field. The address and the value are the same node, because
// an owner is a struct, which lowering passes by address.
@(private)
lower_selector_receiver :: proc(state: ^Procedure_State, node: syntax.Node_Index, argument: check.Call_Argument, owner: ir.Node_Id) -> ir.Node_Id {
	base, is_ref := argument.value.(check.Expression_Ref)
	if !is_ref || owner == 0 { return lower_fail(state, node, .Call_Argument) }
	if argument.receiver != .Box { return owner }
	plan := check.plan(state.job.program, argument.conversion)
	if plan == nil { return lower_fail(state, node, .Conversion) }
	conversion, is_conversion := plan^.(check.Conversion_Plan)
	if !is_conversion || conversion.kind != .Box { return lower_fail(state, node, .Conversion) }
	return lower_conversion_value(state, conversion, node, lower_info(state, base.node).type, owner)
}

@(private)
lower_selector_place :: proc(state: ^Procedure_State, selector: check.Expression_Ref) -> (place: check.Place_Plan, base: syntax.Node_Index, ok: bool) {
	info, found := check.expression_info(state.job.program, selector.view, selector.node)
	if !found || info.plan == 0 { return {}, 0, false }
	plan := check.plan(state.job.program, info.plan)
	if plan == nil { return {}, 0, false }
	place, ok = plan^.(check.Place_Plan)
	if !ok || len(place.path) == 0 || place.bit_size != 0 { return {}, 0, false }
	root, is_ref := place.root.(check.Expression_Ref)
	if !is_ref { return {}, 0, false }
	return place, root.node, true
}

// The address of the owner: the base's value when it is a pointer, the address of the `using` member holding the
// field, or the base itself.
@(private)
lower_selector_owner_address :: proc(state: ^Procedure_State, base: syntax.Node_Index, prefix: []check.Member_Step) -> ir.Node_Id {
	if len(prefix) > 0 {
		return lower_place(state, check.Place_Plan{root = check.Expression_Ref{state.view, base}, path = prefix}, base)
	}
	return lower_value(state, base)
}

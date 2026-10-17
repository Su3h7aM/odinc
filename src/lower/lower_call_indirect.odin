package lower

import "core:mem/virtual"
import "oc:check"
import "oc:syntax"
import "oc:types"

// A call through a procedure value has no declaration. Its ABI comes from the value's procedure type.
@(private)
call_declaration :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Call_Plan) -> (declaration: Procedure_Declaration, valid: bool) {
	if plan.entity == 0 { return indirect_declaration(state, node, plan) }
	if int(plan.entity) >= len(state.job.declarations) || !direct_call_callee(state, plan) {
		lower_fail(state, node, .Call)
		return {}, false
	}
	declaration = state.job.declarations[plan.entity]
	if declaration.type == 0 {
		lower_fail(state, node, .Call)
		return {}, false
	}
	return declaration, true
}

@(private)
indirect_declaration :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Call_Plan) -> (declaration: Procedure_Declaration, valid: bool) {
	value, is_reference := plan.callee.(check.Expression_Ref)
	if !is_reference || !call_operand_valid(state, plan.callee) {
		lower_fail(state, node, .Call)
		return {}, false
	}
	info := check.expression_info(state.job.program, value.view, value.node)
	store := check.type_store(state.job.program)
	procedure := types.resolve_named(store, info.type)
	descriptor := types.get(store, procedure)
	if descriptor.kind != .Procedure {
		lower_fail(state, node, .Call)
		return {}, false
	}
	allocator := virtual.arena_allocator(&state.job.function.arena)
	abi, abi_error := types.plan_abi(store, procedure, allocator = allocator)
	if abi_error != .None {
		lower_fail(state, node, .Call)
		return {}, false
	}
	signature, signature_error := abi_signature(abi, allocator)
	if signature_error != nil {
		state.job.function.error = signature_error
		return {}, false
	}
	parameters, parameters_error := make([]check.Entity_Id, len(descriptor.params), allocator)
	if parameters_error != nil {
		state.job.function.error = parameters_error
		return {}, false
	}
	return Procedure_Declaration{type = procedure, parameters = parameters, abi_params = abi.params, signature = signature}, true
}

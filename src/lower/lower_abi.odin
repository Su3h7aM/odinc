package lower

import "base:runtime"
import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
Procedure_Declaration :: struct {
	type:       types.Type_Id,
	parameters: []check.Entity_Id,
	abi_params: []types.Abi_Param,
	signature:  ir.Signature,
	symbol:     ir.Symbol_Ref,
}

@(private)
Call_Signature :: struct {
	type: types.Type_Id,
	id:   ir.Signature_Id,
}

// Planned before the parallel phase, so workers only read it: types.plan_abi appends a temporary tuple to the
// shared type store on its C multiple-result path.
@(private)
Planned_Abi :: struct {
	plan:  types.Abi_Plan,
	valid: bool,
}

@(private)
Abi_Plans :: struct {
	procedures:     []Planned_Abi, // by procedure type id, without by-pointer parameters
	foreign_plans:  []Planned_Abi, // by entity id, for bodyless foreign procedures
	call_sites:     []Planned_Abi, // by Plan_Id, for direct calls of C variadic procedures
	va_arg_classes: []types.Classification, // by Plan_Id, for c_va_arg
}

@(private)
prepare_abi_plans :: proc(program: ^check.Checked_Program, allocator: runtime.Allocator) -> (plans: Abi_Plans, err: runtime.Allocator_Error) {
	store := check.type_store(program)
	plans.procedures = make([]Planned_Abi, len(store.types), allocator) or_return
	for index in 1 ..< len(store.types) {
		id := types.Type_Id(index)
		if types.get(store, id).kind != .Procedure { continue }
		plans.procedures[index] = plan_signature(store, id, nil, allocator) or_return
	}
	plans.foreign_plans = make([]Planned_Abi, len(program.entities), allocator) or_return
	for entity, index in program.entities {
		procedure, is_procedure := entity.data.(check.Procedure_Data)
		if !is_procedure || entity.kind != .Procedure || entity.state != .Resolved || .Foreign not_in entity.flags || procedure.body.node != 0 {
			continue
		}
		if procedure.signature == types.TYPE_NONE { continue }
		by_pointer, valid, by_error := procedure_by_pointer(program, procedure, allocator)
		if by_error != nil { return plans, by_error }
		if !valid || types.get(store, types.resolve_named(store, procedure.signature)).kind != .Procedure { continue }
		plans.foreign_plans[index] = plan_signature(store, procedure.signature, by_pointer, allocator) or_return
	}
	plans.call_sites = make([]Planned_Abi, len(program.plan_table), allocator) or_return
	for entry, plan_id in program.plan_table {
		call, is_call := entry.(check.Call_Plan)
		if !is_call || call.entity == 0 || int(call.entity) >= len(program.entities) { continue }
		procedure, is_procedure := program.entities[call.entity].data.(check.Procedure_Data)
		if !is_procedure || procedure.signature == types.TYPE_NONE { continue }
		if !types.get(store, types.resolve_named(store, procedure.signature)).c_vararg { continue }
		fixed_count := len(procedure.parameters) - 1
		if fixed_count < 0 || len(call.arguments) < fixed_count { continue }
		tail := make([]types.Type_Id, len(call.arguments) - fixed_count, allocator) or_return
		for argument, offset in call.arguments[fixed_count:] { tail[offset] = argument.promoted_type }
		by_pointer, valid, by_error := procedure_by_pointer(program, procedure, allocator)
		if by_error != nil { return plans, by_error }
		if !valid { continue }
		plans.call_sites[plan_id] = plan_call_site(store, procedure.signature, by_pointer, tail, allocator) or_return
	}
	plans.va_arg_classes = make([]types.Classification, len(program.plan_table), allocator) or_return
	for entry, plan_id in program.plan_table {
		builtin, is_builtin := entry.(check.Builtin_Plan)
		if !is_builtin || check.builtin_kind(program, builtin.builtin) != .C_Va_Arg || len(builtin.arguments) != 2 { continue }
		requested, is_expression := builtin.arguments[1].(check.Expression_Ref)
		if !is_expression { continue }
		info, found := check.expression_info(program, requested.view, requested.node)
		if !found || info.type == 0 { continue }
		plans.va_arg_classes[plan_id], _ = types.classify(store, info.type)
	}
	return plans, nil
}

@(private)
procedure_by_pointer :: proc(
	program: ^check.Checked_Program,
	procedure: check.Procedure_Data,
	allocator: runtime.Allocator,
) -> (
	by_pointer: []bool,
	valid: bool,
	err: runtime.Allocator_Error,
) {
	by_pointer = make([]bool, len(procedure.parameters), allocator) or_return
	for parameter, position in procedure.parameters {
		if int(parameter) <= 0 || int(parameter) >= len(program.entities) { return by_pointer, false, nil }
		by_pointer[position] = .By_Pointer in program.entities[parameter].flags
	}
	return by_pointer, true, nil
}

@(private)
plan_signature :: proc(
	store: ^types.Store,
	procedure: types.Type_Id,
	by_pointer: []bool,
	allocator: runtime.Allocator,
) -> (
	planned: Planned_Abi,
	err: runtime.Allocator_Error,
) {
	if types.get(store, types.resolve_named(store, procedure)).c_vararg {
		return plan_call_site(store, procedure, by_pointer, nil, allocator)
	}
	plan, plan_error := types.plan_abi(store, procedure, by_pointer, allocator = allocator)
	if plan_error == .Out_Of_Memory { return {}, .Out_Of_Memory }
	return Planned_Abi{plan, plan_error == .None}, nil
}

// A C variadic procedure's own ABI has its fixed parameters only; its tail belongs to each call site.
@(private)
plan_call_site :: proc(
	store: ^types.Store,
	procedure: types.Type_Id,
	by_pointer: []bool,
	tail: []types.Type_Id,
	allocator: runtime.Allocator,
) -> (
	planned: Planned_Abi,
	err: runtime.Allocator_Error,
) {
	plan, plan_error := types.plan_call_abi(store, procedure, by_pointer, tail, allocator = allocator)
	if plan_error == .Out_Of_Memory { return {}, .Out_Of_Memory }
	return Planned_Abi{plan, plan_error == .None}, nil
}

@(private)
prepare_declarations :: proc(
	jobs: []Procedure_Job,
	entity_count: int,
	allocator: runtime.Allocator,
) -> (
	declarations: []Procedure_Declaration,
	err: runtime.Allocator_Error,
) {
	declarations = make([]Procedure_Declaration, entity_count, allocator) or_return
	for job in jobs {
		if len(job.errors) != 0 || job.procedure.generated.kind != .None { continue }
		assert(job.procedure.entity != 0 && int(job.procedure.entity) < entity_count)
		declarations[job.procedure.entity] = {
			type       = job.procedure.signature,
			parameters = job.procedure.parameters,
			abi_params = job.parameters,
			signature  = job.function.signatures[job.function.signature],
			symbol     = job.symbols[job.procedure.symbol],
		}
	}
	return
}

@(private)
call_signature :: proc(state: ^Procedure_State, declaration: Procedure_Declaration) -> ir.Signature_Id {
	if declaration.type == state.job.procedure.signature { return state.job.function.signature }
	for cached in state.call_signatures {
		if cached.type == declaration.type { return cached.id }
	}
	id := ir.add_signature(state.job.function, declaration.signature)
	if state.job.function.error != nil { return 0 }
	if _, err := append(&state.call_signatures, Call_Signature{declaration.type, id}); err != nil { state.job.function.error = err }
	return id
}

@(private)
abi_signature :: proc(plan: types.Abi_Plan, allocator: runtime.Allocator) -> (signature: ir.Signature, err: runtime.Allocator_Error) {
	params := make([]ir.Param, len(plan.params), allocator) or_return
	results := make([]ir.Result, len(plan.results), allocator) or_return
	for parameter, index in plan.params {
		params[index] = {piece_type(parameter.type), ir.Param_Attr(parameter.attr), ir.Extension(parameter.ext), parameter.size, parameter.align}
	}
	for result, index in plan.results {
		results[index] = {piece_type(result.type), ir.Extension(result.ext), result.size}
	}
	return ir.Signature{ir.Calling_Convention(plan.convention), plan.variadic, params, results}, nil
}

@(private)
call_scalar_type :: proc(type: ir.Value_Type) -> bool {
	#partial switch type {
	case .I8, .I16, .I32, .I64, .F32, .F64, .Ptr:
		return true
	}
	return false
}

@(private)
c_vararg_call_declaration :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	declaration: Procedure_Declaration,
) -> (
	Procedure_Declaration,
	bool,
) {
	if int(info.plan) >= len(state.job.abi_plans.call_sites) {
		lower_fail(state, node, .Call)
		return {}, false
	}
	planned := state.job.abi_plans.call_sites[info.plan]
	if !planned.valid {
		lower_fail(state, node, .Call)
		return {}, false
	}
	allocator := virtual.arena_allocator(&state.job.function.arena)
	signature, signature_error := abi_signature(planned.plan, allocator)
	if signature_error != nil {
		state.job.function.error = signature_error
		return {}, false
	}
	return Procedure_Declaration {
			type = declaration.type,
			parameters = declaration.parameters[:len(declaration.parameters) - 1],
			abi_params = planned.plan.params,
			signature = signature,
			symbol = declaration.symbol,
		},
		true
}

// The call's own descriptor: the fixed parameter types, then each tail argument's promoted type.
@(private)
c_vararg_call_descriptor :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	descriptor: ^types.Type,
	arguments: []check.Call_Argument,
) -> (
	^types.Type,
	bool,
) {
	fixed_count := len(descriptor.params) - 1
	allocator := virtual.arena_allocator(&state.job.function.arena)
	params, params_error := make([]types.Type_Id, len(arguments), allocator)
	if params_error != nil {
		state.job.function.error = params_error
		return nil, false
	}
	for argument, index in arguments {
		params[index] = descriptor.params[index] if index < fixed_count else argument.promoted_type
		if params[index] == 0 {
			lower_fail(state, node, .Call_Argument)
			return nil, false
		}
	}
	extended, extended_error := new(types.Type, allocator)
	if extended_error != nil {
		state.job.function.error = extended_error
		return nil, false
	}
	extended^ = descriptor^
	extended.params = params
	return extended, true
}

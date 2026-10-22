package lower

import "base:runtime"
import "oc:check"
import "oc:ir"
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
	procedures:    []Planned_Abi, // by procedure type id, without by-pointer parameters
	foreign_plans: []Planned_Abi, // by entity id, for bodyless foreign procedures
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
		by_pointer := make([]bool, len(procedure.parameters), allocator) or_return
		valid := true
		for parameter, position in procedure.parameters {
			if int(parameter) <= 0 || int(parameter) >= len(program.entities) {
				valid = false
				break
			}
			by_pointer[position] = .By_Pointer in program.entities[parameter].flags
		}
		if !valid || types.get(store, types.resolve_named(store, procedure.signature)).kind != .Procedure { continue }
		plans.foreign_plans[index] = plan_signature(store, procedure.signature, by_pointer, allocator) or_return
	}
	return plans, nil
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
	plan, plan_error := types.plan_abi(store, procedure, by_pointer, allocator = allocator)
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

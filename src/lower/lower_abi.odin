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

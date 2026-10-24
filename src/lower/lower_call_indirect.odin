package lower

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "oc:check"
import "oc:ir"
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
	if declaration.type != 0 { return declaration, true }
	return extern_declaration(state, node, plan)
}

@(private)
extern_declaration :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Call_Plan) -> (declaration: Procedure_Declaration, valid: bool) {
	program := state.job.program
	if int(plan.entity) >= len(program.entities) {
		lower_fail(state, node, .Call)
		return {}, false
	}
	entity := program.entities[plan.entity]
	if entity.kind != .Procedure || .Foreign not_in entity.flags {
		lower_fail(state, node, .Call)
		return {}, false
	}
	procedure, is_procedure := entity.data.(check.Procedure_Data)
	if !is_procedure || procedure.body.node != 0 {
		lower_fail(state, node, .Call)
		return {}, false
	}
	planned := state.job.abi_plans.foreign_plans[plan.entity]
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
	source_symbol := check.entity_symbol(program, plan.entity)
	if source_symbol == 0 || state.job.symbols[source_symbol].space != .Extern {
		lower_fail(state, node, .Call)
		return {}, false
	}
	symbol := state.job.symbols[source_symbol]
	return Procedure_Declaration {
			type = procedure.signature,
			parameters = procedure.parameters,
			abi_params = planned.plan.params,
			signature = signature,
			symbol = symbol,
		},
		true
}

@(private = "file")
extern_index :: proc(module: ^ir.Module, name: string, source_count: u32) -> (index: u32, found: bool) {
	for extern, position in module.externs {
		if u32(position) < source_count { continue }
		if extern.name == name { return u32(position), true }
	}
	return 0, false
}

// Compiler-generated externs stay separate from source declarations until reachability records their library provenance.
@(private)
extern_symbol :: proc(state: ^Procedure_State, name: string) -> (symbol: ir.Symbol_Ref, valid: bool) {
	job := state.job
	for existing, position in job.extern_names {
		if existing == name { return ir.Symbol_Ref{space = .Extern, index = job.extern_base + u32(position)}, true }
	}
	allocator := virtual.arena_allocator(&job.function.arena)
	stored, clone_error := strings.clone(name, allocator)
	if clone_error != nil {
		job.function.error = clone_error
		return {}, false
	}
	if len(job.extern_names) == 0 { job.extern_base = u32(len(job.module.externs)) }
	if _, append_error := append(&job.extern_names, stored); append_error != nil {
		job.function.error = append_error
		return {}, false
	}
	return ir.Symbol_Ref{space = .Extern, index = job.extern_base + u32(len(job.extern_names) - 1)}, true
}

// Interns a job's new extern names in order and rewrites its local extern references to module indices.
@(private)
merge_job_externs :: proc(module: ^ir.Module, job: ^Procedure_Job) -> runtime.Allocator_Error {
	if len(job.extern_names) == 0 { return nil }
	function := job.function
	indices := make([]u32, len(job.extern_names), virtual.arena_allocator(&function.arena)) or_return
	module_allocator := virtual.arena_allocator(&module.arena)
	source_count: u32
	for symbol in job.symbols {
		if symbol.space == .Extern { source_count = max(source_count, symbol.index + 1) }
	}
	for name, position in job.extern_names {
		index, found := extern_index(module, name, source_count)
		if !found {
			index = u32(len(module.externs))
			append(&module.externs, ir.Extern{name = strings.clone(name, module_allocator) or_return}) or_return
		}
		indices[position] = index
	}
	for index in 1 ..< len(function.nodes) {
		kind := function.nodes.kind[index]
		if kind != .Symbol_Addr && kind != .Tls_Addr { continue }
		symbol := function.nodes.data[index].symbol
		if symbol.space == .Extern && symbol.index >= job.extern_base {
			function.nodes.data[index].symbol.index = indices[symbol.index - job.extern_base]
		}
	}
	for &blob in function.blobs {
		for &reloc in blob.relocs {
			if reloc.target.space == .Extern && reloc.target.index >= job.extern_base {
				reloc.target.index = indices[reloc.target.index - job.extern_base]
			}
		}
	}
	return nil
}

@(private)
merge_module_externs :: proc(module: ^ir.Module, scratch: runtime.Allocator) -> runtime.Allocator_Error {
	indices := make([]u32, len(module.externs), scratch) or_return
	names := make(map[string]u32, len(module.externs), allocator = scratch) or_return
	kept := 0
	for extern, index in module.externs {
		merged, found := names[extern.name]
		if !found {
			merged = u32(kept)
			names[extern.name] = merged
			module.externs[kept] = extern
			kept += 1
		}
		indices[index] = merged
	}
	resize(&module.externs, kept) or_return
	for function in module.functions {
		for index in 1 ..< len(function.nodes) {
			if function.nodes.kind[index] != .Symbol_Addr && function.nodes.kind[index] != .Tls_Addr { continue }
			symbol := &function.nodes.data[index].symbol
			if symbol.space == .Extern { symbol.index = indices[symbol.index] }
		}
		for &blob in function.blobs {
			for &reloc in blob.relocs {
				if reloc.target.space == .Extern { reloc.target.index = indices[reloc.target.index] }
			}
		}
	}
	for &global in module.globals {
		for &reloc in global.relocs {
			if reloc.target.space == .Extern { reloc.target.index = indices[reloc.target.index] }
		}
	}
	return nil
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
	planned := state.job.abi_plans.procedures[procedure]
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
	parameters, parameters_error := make([]check.Entity_Id, len(descriptor.params), allocator)
	if parameters_error != nil {
		state.job.function.error = parameters_error
		return {}, false
	}
	return Procedure_Declaration{type = procedure, parameters = parameters, abi_params = planned.plan.params, signature = signature}, true
}

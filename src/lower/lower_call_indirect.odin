package lower

import "base:runtime"
import "core:mem/virtual"
import "core:strconv"
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

// A bodyless foreign procedure has no job and no checker symbol. Its ABI comes
// from its planned signature and its address from an extern of its link name.
// Anything else without a declaration keeps the call failure above.
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
	link_name := foreign_link_name(program, plan.entity, allocator)
	symbol, symbol_valid := extern_symbol(state, link_name)
	if !symbol_valid { return {}, false }
	return Procedure_Declaration {
			type = procedure.signature,
			parameters = procedure.parameters,
			abi_params = planned.plan.params,
			signature = signature,
			symbol = symbol,
		},
		true
}

// The checker's symbol name for a foreign procedure: its link name attribute,
// else its bare name. The name is cloned for the module extern below.
@(private)
foreign_link_name :: proc(program: ^check.Checked_Program, entity: check.Entity_Id, allocator := context.allocator) -> string {
	declaration := program.entities[entity].declaration
	if declaration.node == 0 || int(declaration.file) <= 0 || int(declaration.file) >= len(program.files) {
		return program.entities[entity].name
	}
	file := program.files[declaration.file]
	if file.ast == nil || int(declaration.node) <= 0 || int(declaration.node) >= len(file.ast.nodes) {
		return program.entities[entity].name
	}
	if file.ast.nodes[declaration.node].kind != .Value_Decl {
		return program.entities[entity].name
	}
	decl := syntax.node_payload(file.ast, declaration.node, syntax.Value_Decl)
	for attribute in syntax.node_list(file.ast, decl.attributes) {
		for element in syntax.node_list(file.ast, syntax.node_payload(file.ast, attribute, syntax.Attribute).elems) {
			identifier := element
			value: syntax.Node_Index
			if file.ast.nodes[element].kind == .Field_Value {
				field := syntax.node_payload(file.ast, element, syntax.Field_Value)
				identifier, value = field.field, field.value
			}
			span := file.ast.nodes[identifier]
			if string(file.source[span.start:span.end]) != "link_name" { continue }
			if value == 0 || file.ast.nodes[value].kind != .Basic_Lit { return program.entities[entity].name }
			kind := syntax.node_payload(file.ast, value, syntax.Basic_Lit).kind
			if kind != .String && kind != .Raw_String { return program.entities[entity].name }
			literal := file.ast.nodes[value]
			if text, _, ok := strconv.unquote_string(string(file.source[literal.start:literal.end]), allocator); ok {
				return text
			}
			return program.entities[entity].name
		}
	}
	return program.entities[entity].name
}

@(private = "file")
extern_index :: proc(module: ^ir.Module, name: string) -> (index: u32, found: bool) {
	for extern, position in module.externs {
		if extern.name == name { return u32(position), true }
	}
	return 0, false
}

// Names an extern for this job. A name already in the module keeps its index; a new name gets extern_base plus its
// position in the job. merge_job_externs interns the new names in job order, so indices never depend on timing.
@(private)
extern_symbol :: proc(state: ^Procedure_State, name: string) -> (symbol: ir.Symbol_Ref, valid: bool) {
	job := state.job
	if index, found := extern_index(job.module, name); found { return ir.Symbol_Ref{space = .Extern, index = index}, true }
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
	for name, position in job.extern_names {
		index, found := extern_index(module, name)
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

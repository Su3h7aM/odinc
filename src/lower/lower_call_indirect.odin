package lower

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
// from its declared signature and its address from an extern of its link name.
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
	store := check.type_store(program)
	descriptor := types.get(store, types.resolve_named(store, procedure.signature))
	if descriptor.kind != .Procedure {
		lower_fail(state, node, .Call)
		return {}, false
	}
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	by_pointer, pointer_error := make([]bool, len(procedure.parameters), allocator)
	if pointer_error != nil {
		function.error = pointer_error
		return {}, false
	}
	for parameter, index in procedure.parameters {
		if int(parameter) <= 0 || int(parameter) >= len(program.entities) {
			lower_fail(state, node, .Call)
			return {}, false
		}
		by_pointer[index] = .By_Pointer in program.entities[parameter].flags
	}
	abi, abi_error := types.plan_abi(store, procedure.signature, by_pointer, allocator = allocator)
	if abi_error != .None {
		lower_fail(state, node, .Call)
		return {}, false
	}
	signature, signature_error := abi_signature(abi, allocator)
	if signature_error != nil {
		function.error = signature_error
		return {}, false
	}
	link_name := foreign_link_name(program, plan.entity, allocator)
	symbol, symbol_valid := extern_symbol(state, node, link_name)
	if !symbol_valid { return {}, false }
	declaration = Procedure_Declaration {
		type       = procedure.signature,
		parameters = procedure.parameters,
		abi_params = abi.params,
		signature  = signature,
		symbol     = symbol,
	}
	state.job.declarations[plan.entity] = declaration
	return declaration, true
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

// The extern of a name, reusing the existing entry. Lowering runs one worker
// today, so the shared module table needs no lock; revisit with worker_count.
@(private)
extern_symbol :: proc(state: ^Procedure_State, node: syntax.Node_Index, name: string) -> (symbol: ir.Symbol_Ref, valid: bool) {
	module := state.job.module
	if module == nil {
		lower_fail(state, node, .Call)
		return {}, false
	}
	for extern, index in module.externs {
		if extern.name == name { return ir.Symbol_Ref{space = .Extern, index = u32(index)}, true }
	}
	stored, clone_error := strings.clone(name, virtual.arena_allocator(&module.arena))
	if clone_error != nil {
		state.job.function.error = clone_error
		return {}, false
	}
	index := len(module.externs)
	append(&module.externs, ir.Extern{name = stored})
	return ir.Symbol_Ref{space = .Extern, index = u32(index)}, true
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

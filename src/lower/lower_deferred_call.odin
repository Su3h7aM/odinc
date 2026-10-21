package lower

import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"

@(private)
Deferred_Call :: struct {
	callee:    ir.Node_Id,
	signature: ir.Signature_Id,
	arguments: []ir.Node_Id,
}

@(private)
Deferred_Action :: union {
	syntax.Node_Index,
	Deferred_Call,
}

@(private)
register_deferred_call :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Call_Plan, inputs, outputs: []ir.Node_Id) {
	declaration, valid := call_declaration(state, node, check.Call_Plan{entity = plan.deferred, callee = plan.deferred})
	if !valid { return }
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	input_values, output_values: []ir.Node_Id
	for attribute in state.job.program.entities[plan.entity].attributes {
		if attribute.entity != plan.deferred { continue }
		switch attribute.name {
		case "deferred_in":
			input_values = inputs
		case "deferred_out":
			output_values = outputs
		case "deferred_in_out":
			input_values, output_values = inputs, outputs
		case "deferred_none":
		case:
			lower_fail(state, node, .Call); return
		}
	}
	descriptor := lower_type(state, declaration.type)
	if len(descriptor.params) != len(input_values) + len(output_values) { lower_fail(state, node, .Call_Argument); return }
	arguments, err := make([]ir.Node_Id, len(declaration.signature.params), allocator)
	if err != nil { function.error = err; return }
	for type, position in descriptor.params {
		value: ir.Node_Id
		if position < len(input_values) { value = input_values[position] } else { value = output_values[position - len(input_values)] }
		first := source_index(declaration.abi_params, position)
		if first < 0 { lower_fail(state, node, .Call_Argument); return }
		span := parameter_span(declaration.abi_params[first:])
		if is_aggregate(state, type) {
			if !pass_aggregate_argument(
				state,
				value,
				type,
				declaration.abi_params[first:first + span],
				arguments[first:first + span],
			) { lower_fail(state, node, .Call_Argument); return }
		} else {
			if span != 1 { lower_fail(state, node, .Call_Argument); return }
			if function.nodes.type[value] == .Bool && declaration.signature.params[first].type == .I8 { value = ir.convert(function, .Zext, value, .I8) }
			arguments[first] = value
		}
	}
	if declaration.signature.cc == .Odin {
		arguments[len(arguments) - 1] = state.context_pointer
		if arguments[len(arguments) - 1] == 0 { arguments[len(arguments) - 1] = ir.symbol_addr(function, state.job.default_context) }
	}
	for argument in arguments { if argument == 0 { lower_fail(state, node, .Call_Argument); return } }
	action := Deferred_Call {
		callee    = ir.symbol_addr(function, declaration.symbol),
		signature = call_signature(state, declaration),
		arguments = arguments,
	}
	if _, append_error := append(&state.defers, Deferred_Action(action)); append_error != nil { function.error = append_error }
}

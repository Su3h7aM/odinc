package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_type_assertion :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Type_Assertion_Plan) -> (value, ok: ir.Node_Id) {
	source_value := lower_operand(state, plan.source)
	if state.failed || state.job.function.error != nil { return }
	store := check.type_store(state.job.program)
	source_type := types.resolve_named(store, plan.source_type)
	source_descriptor := types.get(store, source_type)
	pointer_source := source_descriptor.kind == .Pointer
	if pointer_source {
		source_type = types.resolve_named(store, source_descriptor.elem)
		source_descriptor = types.get(store, source_type)
	}
	subject, subject_ok := lower_type_switch_subject(state, node, source_type, source_value)
	if !subject_ok { return }
	if plan.comma_ok || plan.policy != .Disabled {
		ok = lower_type_switch_test(state, node, subject, plan.target_type)
	}
	if state.failed || state.job.function.error != nil { return }
	if !plan.comma_ok && plan.policy != .Disabled { lower_check(state, ok) }
	function := state.job.function
	if source_descriptor.kind == .Any { source_value = lower_load_word(state, source_value, .Ptr) } else { source_value = subject.address }
	if plan.comma_ok {
		layout := state.job.layouts[plan.target_type]
		if layout.error != .None || layout.size < 0 || layout.size > i64(max(u32)) { lower_fail(state, node, .Expression); return }
		if scalar := scalar_type(state, plan.target_type); scalar != .None {
			zero: ir.Node_Id
			if is_float_type(scalar) {
				zero = ir.const_float(function, scalar, 0)
			} else {
				zero = ir.const_int(function, scalar, 0)
			}
			result := ir.variable_declare(state.builder, zero)
			end := ir.jump_target_make(state.builder)
			branch := ir.branch_if(state.builder, ok)
			ir.enter_arm(state.builder, branch, 0)
			payload := lower_load(state, source_value, plan.target_type)
			if state.failed || function.error != nil { return }
			ir.variable_set(state.builder, result, payload)
			ir.jump_to(state.builder, end)
			ir.enter_arm(state.builder, branch, 1)
			ir.jump_to(state.builder, end)
			ir.seal_target(state.builder, end)
			value = ir.variable_get(state.builder, result)
		} else {
			value = ir.stack_slot(function, state.entry_control, u32(max(layout.size, 1)), u32(layout.align))
			zero_memory := ir.add_node(
				function,
				.Mem_Set,
				.Memory,
				{
					state.builder.control,
					ir.variable_get(state.builder, ir.MEMORY_VARIABLE),
					value,
					ir.const_int(function, .I8, 0),
					ir.const_int(function, .I64, layout.size),
				},
			)
			ir.variable_set(state.builder, ir.MEMORY_VARIABLE, zero_memory)
			end := ir.jump_target_make(state.builder)
			branch := ir.branch_if(state.builder, ok)
			ir.enter_arm(state.builder, branch, 0)
			payload := lower_load(state, source_value, plan.target_type)
			if state.failed || function.error != nil { return }
			lower_store(state, value, payload, plan.target_type)
			ir.jump_to(state.builder, end)
			ir.enter_arm(state.builder, branch, 1)
			ir.jump_to(state.builder, end)
			ir.seal_target(state.builder, end)
		}
	} else {
		value = lower_load(state, source_value, plan.target_type)
	}
	return
}

// Address of a type assertion payload, for `&x.(T)`. The checker only marks an
// assertion addressable when the payload has a stable address, so the subject
// address is usable directly; `any` payloads live behind the data word.
@(private)
lower_type_assertion_address :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Type_Assertion_Plan) -> ir.Node_Id {
	address, _ := lower_type_assertion_pointer(state, node, plan)
	return address
}

@(private)
lower_type_assertion_pointer :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Type_Assertion_Plan) -> (address, ok: ir.Node_Id) {
	source_value := lower_operand(state, plan.source)
	if state.failed || state.job.function.error != nil { return }
	store := check.type_store(state.job.program)
	source_type := types.resolve_named(store, plan.source_type)
	source_descriptor := types.get(store, source_type)
	pointer_source := source_descriptor.kind == .Pointer
	if pointer_source {
		source_type = types.resolve_named(store, source_descriptor.elem)
		source_descriptor = types.get(store, source_type)
	}
	subject, subject_ok := lower_type_switch_subject(state, node, source_type, source_value)
	if !subject_ok { return }
	if plan.comma_ok || plan.policy != .Disabled {
		ok = lower_type_switch_test(state, node, subject, plan.target_type)
	}
	if state.failed || state.job.function.error != nil { return }
	if !plan.comma_ok && plan.policy != .Disabled { lower_check(state, ok) }
	address = subject.address
	if source_descriptor.kind == .Any { address = lower_load_word(state, source_value, .Ptr) }
	if plan.comma_ok { address = ir.select(state.job.function, ok, address, ir.const_int(state.job.function, .Ptr, 0)) }
	return
}

@(private)
lower_optional_address :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> (address, ok: ir.Node_Id) {
	address_node := node
	for state.ast.nodes[address_node].kind == .Paren_Expr { address_node = state.ast.nodes[address_node].payload.(syntax.Paren_Expr).expr }
	operand := state.ast.nodes[address_node].payload.(syntax.Unary_Expr).expr
	info := lower_info(state, operand)
	plan := check.plan(state.job.program, info.plan)
	if plan == nil { lower_fail(state, node, .Expression); return }
	if map_index, is_map := plan^.(check.Map_Index_Plan); is_map {
		address, ok, _ = lower_map_entry(state, operand, map_index)
		return
	}
	assertion, is_assertion := plan^.(check.Type_Assertion_Plan)
	if !is_assertion { lower_fail(state, node, .Expression); return }
	assertion.comma_ok = true
	return lower_type_assertion_pointer(state, operand, assertion)
}

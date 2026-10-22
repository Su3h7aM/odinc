package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	callee: Expression_Info,
	arguments: []syntax.Node_Index,
	spread: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	scopes := checker.type_checker.resolver.scopes
	procedure := entity_get(scopes, callee.entity).data.(Procedure_Data)
	if procedure.signature == types.TYPE_NONE { return expression_missing_operand_type(checker, view, scope, node, callee.mode) }
	descriptor := types.get(checker.type_checker.store, procedure.signature)^
	parameter_count := len(procedure.parameters)
	if len(descriptor.params) != parameter_count {
		return expression_unsupported(checker, view, scope, node, "Call_Signature")
	}
	allowed, context_error := expression_require_call_context(checker, view, scope, node, descriptor.convention)
	if context_error != nil { return {}, context_error }
	if !allowed { return expression_poison(scope), nil }
	if descriptor.c_vararg || descriptor.variadic && descriptor.convention != .Odin && descriptor.convention != .Contextless && descriptor.convention != .C {
		return expression_unsupported(checker, view, scope, node, "Call_Variadic_Convention")
	}
	file := checker.type_checker.files[file_id]
	positional_count := call_positional_count(file, arguments)
	variadic_index := procedure.variadic_index
	if spread {
		if !descriptor.variadic || variadic_index < 0 {
			return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread")
		}
		if positional_count > variadic_index + 1 {
			return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread_Arguments")
		}
		if positional_count != variadic_index + 1 {
			return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread_Position")
		}
	}
	expansions := call_expansions(checker, view, scope, file, arguments[:positional_count]) or_return
	expanded_count := len(arguments)
	for results in expansions {
		if results != nil { expanded_count += len(results) - 1 }
	}
	if expansions != nil && spread {
		return expression_unsupported(checker, view, scope, node, "Call_Tuple_Variadic_Spread")
	}
	if !descriptor.variadic && expanded_count > parameter_count {
		return expression_unsupported(checker, view, scope, node, "Call_Arguments")
	}
	packed := descriptor.variadic && !spread
	fixed_count := parameter_count
	if packed || spread { fixed_count = parameter_count if spread else variadic_index }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	names := make([]string, parameter_count, allocator) or_return
	for parameter, index in procedure.parameters {
		names[index] = entity_get(scopes, parameter).name
	}
	slots := make([]Call_Slot, parameter_count, allocator) or_return
	if reason := call_bind_arguments(file, arguments, names, fixed_count, slots, expansions); reason != "" {
		return expression_unsupported(checker, view, scope, node, reason)
	}
	if packed && slots[variadic_index].value != 0 {
		if positional_count > fixed_count {
			return expression_unsupported(checker, view, scope, node, "Call_Variadic_Named")
		}
		packed = false
	}
	call_arguments := make([]Call_Argument, parameter_count, allocator) or_return
	for index in 0 ..< parameter_count {
		if slots[index].value != 0 {
			argument, valid := expression_call_slot_argument(
				checker,
				view,
				scope,
				slots[index],
				expansions,
				descriptor.params[index],
				procedure.parameters[index],
			) or_return
			if !valid { return expression_poison(scope), nil }
			if spread && index == variadic_index { argument.variadic_spread = true }
			call_arguments[index] = argument
			continue
		}
		if packed && index == variadic_index { continue }
		if index >= len(procedure.defaults) { return expression_unsupported(checker, view, scope, node, "Call_Default_Missing") }
		argument, valid := expression_call_default_argument(
			checker,
			view,
			scope,
			node,
			names,
			slots,
			procedure.defaults[index],
			procedure.parameters[index],
			u32(len(arguments) + index),
		) or_return
		if !valid { return expression_poison(scope), nil }
		call_arguments[index] = argument
	}
	if packed {
		pack_start := min(positional_count, fixed_count)
		order := u32(len(arguments) + fixed_count)
		if pack_start < positional_count { order = u32(pack_start) }
		variadic, reason, valid := expression_variadic_argument(
			checker,
			view,
			scope,
			arguments[:positional_count],
			expansions,
			fixed_count,
			procedure.parameters[variadic_index],
			descriptor.params[variadic_index],
			order,
			allocator,
		) or_return
		if reason != "" { return expression_unsupported(checker, view, scope, node, reason) }
		if !valid { return expression_poison(scope), nil }
		call_arguments[variadic_index] = variadic
	}
	results := make([]types.Type_Id, len(descriptor.results), allocator) or_return
	copy(results, descriptor.results)
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(Call_Plan{callee = Operand(callee.entity), entity = callee.entity, arguments = call_arguments, results = results, variadic = packed}),
	) or_return
	info = Expression_Info {
		scope = scope,
		state = .Checked,
		plan  = plan,
		mode  = .No_Value,
	}
	if len(results) == 1 { info.type, info.mode = results[0], .Value }
	return info, nil
}

// A supplied argument, or one result of a multi-result call, converted to its parameter type.
@(private = "package")
expression_call_slot_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	slot: Call_Slot,
	expansions: [][]types.Type_Id,
	target: types.Type_Id,
	parameter: Entity_Id,
	any_integer: bool = false,
	no_broadcast: bool = false,
) -> (
	argument: Call_Argument,
	valid: bool,
	err: Resolve_Error,
) {
	order := u32(slot.position)
	if slot.element == 0 {
		return expression_call_argument(checker, view, scope, slot.value, target, parameter, order, any_integer, no_broadcast)
	}
	return expression_call_tuple_argument(
		checker,
		view,
		scope,
		slot.value,
		expansions[slot.position][slot.element - 1],
		target,
		parameter,
		slot.element,
		order,
	)
}

// One result of a multi-result call converted to its parameter type. The argument names the call and the result it
// supplies; the call is evaluated once, and the conversion applies to the result it produced.
@(private = "file")
expression_call_tuple_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	value_node: syntax.Node_Index,
	result: types.Type_Id,
	target: types.Type_Id,
	parameter: Entity_Id,
	element: int,
	order: u32,
) -> (
	argument: Call_Argument,
	valid: bool,
	err: Resolve_Error,
) {
	info := Expression_Info {
		type  = result,
		mode  = .Value,
		scope = scope,
		state = .Checked,
	}
	converted := expression_conversion(checker, view, scope, value_node, Operand(Expression_Ref{view, value_node}), info, target, .Assignment) or_return
	if converted.state == .Invalid { return {}, false, nil }
	conversion: Plan_Id
	if !types.are_identical(checker.type_checker.store, result, target) {
		retained := checker.plans[converted.plan].(Conversion_Plan)
		retained.source_type = result
		conversion = Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(retained)) or_return
	}
	return Call_Argument {
			value = Operand(Expression_Ref{view, value_node}),
			parameter = parameter,
			conversion = conversion,
			evaluation_order = order,
			tuple_element = element,
		},
		true,
		nil
}

// The conversion of one result of a multi-result call to the type its parameter needs, without a diagnostic: the
// caller reports the failure in its own terms. The plan's source is the call, and its source type is the result it
// converts, so lowering applies the plan to the result the call produced.
@(private = "file")
call_result_conversion :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	value_node: syntax.Node_Index,
	result: types.Type_Id,
	target: types.Type_Id,
) -> (
	plan: Plan_Id,
	ok: bool,
	err: Resolve_Error,
) {
	info := Expression_Info {
		type  = result,
		mode  = .Value,
		scope = scope,
		state = .Checked,
	}
	converted, diagnostic, conversion_error := check_conversion(
		checker.constants,
		checker.type_checker.store,
		Operand(Expression_Ref{view, value_node}),
		info,
		target,
		.Assignment,
		checker.config,
	)
	if conversion_error != nil { return {}, false, nil }
	if diagnostic != .None { return {}, false, nil }
	conversion := converted.plan
	conversion.source_type = result
	if conversion.kind == .Box { expression_record_type_info(checker, result) or_return }
	plan = Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(conversion)) or_return
	return plan, true, nil
}

// An operand that splats into an array parameter or element publishes the Broadcast plan of the assignment
// conversion, as an assignment does. Other operands publish no plan here.
@(private = "file")
call_argument_broadcast :: proc(
	checker: ^Expression_Checker,
	source: Operand,
	value: Expression_Info,
	target: types.Type_Id,
) -> (
	plan: Plan_Id,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	if types.get(store, types.resolve_named(store, target)).kind != .Array { return 0, nil }
	info := value
	if value.type == target {
		// A constant argument arrives already typed as the parameter; its own untyped type decides the splat.
		constant := constant_pool_get(checker.constants, value.constant)
		if value.mode != .Constant || constant == nil || !conversion_untyped(types.get(store, constant.type).kind) { return 0, nil }
		info.type = constant.type
	}
	converted, diagnostic, conversion_error := check_conversion(checker.constants, store, source, info, target, .Assignment, checker.config)
	if conversion_error != nil || diagnostic != .None || converted.plan.kind != .Broadcast { return 0, nil }
	plan = Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(converted.plan)) or_return
	return plan, nil
}

// A supplied argument converted to its parameter type. The call retains the conversion plan, if any.
@(private = "file")
expression_call_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	value_node: syntax.Node_Index,
	target: types.Type_Id,
	parameter: Entity_Id,
	order: u32,
	any_integer: bool = false,
	no_broadcast: bool = false,
) -> (
	argument: Call_Argument,
	valid: bool,
	err: Resolve_Error,
) {
	accept_any_integer := any_integer
	if parameter != 0 { accept_any_integer = .Any_Integer in entity_get(checker.type_checker.resolver.scopes, parameter).flags }
	value := expression_argument(checker, view, scope, value_node, target, accept_any_integer) or_return
	if value.state == .Invalid { return {}, false, nil }
	operand := Operand(Expression_Ref{view, value_node})
	if value.mode == .Constant { operand = Operand(value.constant) }
	conversion := expression_conversion_plan(checker, value.plan)
	if conversion != 0 {
		retained := checker.plans[conversion].(Conversion_Plan)
		if _, is_constant := retained.source.(Const_Id); !is_constant {
			program: Checked_Program
			expression_checker_publish(checker, &program)
			expression := expression_info(&program, view, value_node)
			if conversion == expression.plan { conversion = 0 }
		}
	}
	if conversion != 0 {
		retained := checker.plans[conversion].(Conversion_Plan)
		// A constant conversion already names its constant as the source. Rebinding it to the
		// argument node would box the hint-converted row type instead of the constant's own type.
		if constant, is_constant := retained.source.(Const_Id); is_constant {
			operand = Operand(constant)
		} else {
			retained.source = operand
		}
		conversion = Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(retained)) or_return
	} else {
		conversion = call_argument_broadcast(checker, operand, value, target) or_return
	}
	if no_broadcast || parameter != 0 && .No_Broadcast in entity_get(checker.type_checker.resolver.scopes, parameter).flags {
		rejected := call_broadcast_rejected(checker, view, value_node, conversion) or_return
		if rejected { return {}, false, nil }
	}
	return Call_Argument{value = operand, parameter = parameter, conversion = conversion, evaluation_order = order}, true, nil
}

// A broadcast onto a `#no_broadcast` parameter is not assignable; records the diagnostic at the argument.
@(private = "file")
call_broadcast_rejected :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	value_node: syntax.Node_Index,
	conversion: Plan_Id,
) -> (
	rejected: bool,
	err: Resolve_Error,
) {
	plan, is_conversion := checker.plans[conversion].(Conversion_Plan)
	if conversion == 0 || !is_conversion || plan.kind != .Broadcast { return false, nil }
	span := checker.type_checker.files[checker.views[view].file].ast.nodes[value_node]
	append(
		&checker.diagnostics,
		Expression_Diagnostic{kind = .Conversion, source = {checker.views[view].file, span.start, span.end}, conversion = .Not_Assignable},
	) or_return
	return true, nil
}

// The trailing arguments of a variadic call become the elements of one slice argument. Non-constant
// elements must already have the element type; constants take it from the parameter at lowering. A multi-result
// call contributes one element per result from the first_element on, each naming the call and its 1-based result.
// Every result converts to the element type, as official check_call_arguments_internal does for variadic operands.
@(private = "file")
expression_variadic_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	arguments: []syntax.Node_Index,
	expansions: [][]types.Type_Id,
	first_element: int,
	parameter: Entity_Id,
	slice_type: types.Type_Id,
	order: u32,
	allocator: mem.Allocator,
) -> (
	argument: Call_Argument,
	reason: string,
	valid: bool,
	err: Resolve_Error,
) {
	element_type := types.get(checker.type_checker.store, slice_type).elem
	elements := make([dynamic]Operand, allocator) or_return
	conversions := make([dynamic]Plan_Id, allocator) or_return
	tuple_elements := make([dynamic]int, allocator) or_return
	flat := 0
	for element, position in arguments {
		results: []types.Type_Id
		if expansions != nil { results = expansions[position] }
		if results != nil {
			for result, offset in results {
				flat += 1
				if flat <= first_element { continue }
				conversion: Plan_Id
				if !types.are_identical(checker.type_checker.store, result, element_type) {
					plan, ok := call_result_conversion(checker, view, scope, element, result, element_type) or_return
					if !ok { return {}, "Call_Tuple_Variadic_Type", false, nil }
					conversion = plan
				}
				append(&elements, Operand(Expression_Ref{view, element})) or_return
				append(&conversions, conversion) or_return
				append(&tuple_elements, offset + 1) or_return
			}
			continue
		}
		flat += 1
		if flat <= first_element { continue }
		value := expression_argument(checker, view, scope, element, element_type, false) or_return
		if value.state == .Invalid { return {}, "", false, nil }
		operand: Operand
		conversion: Plan_Id
		switch {
		case value.constant != 0:
			operand = Operand(value.constant)
			conversion = call_argument_broadcast(checker, operand, value, element_type) or_return
		case expression_conversion_plan(checker, value.plan) != 0:
			operand = Operand(Expression_Ref{view, element})
			conversion = value.plan
		case:
			operand = Operand(Expression_Ref{view, element})
		}
		if parameter != 0 && .No_Broadcast in entity_get(checker.type_checker.resolver.scopes, parameter).flags {
			rejected := call_broadcast_rejected(checker, view, element, conversion) or_return
			if rejected { return {}, "", false, nil }
		}
		append(&elements, operand) or_return
		append(&conversions, conversion) or_return
		append(&tuple_elements, 0) or_return
	}
	return Call_Argument {
			parameter = parameter,
			evaluation_order = order,
			variadic_pack = true,
			variadic_elements = elements[:],
			variadic_conversions = conversions[:],
			variadic_tuple_elements = tuple_elements[:],
		},
		"",
		true,
		nil
}

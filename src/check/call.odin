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
	descriptor := types.get(checker.type_checker.store, procedure.signature)
	parameter_count := len(procedure.parameters)
	if len(descriptor.params) != parameter_count {
		return expression_unsupported(checker, view, scope, node, "Call_Signature")
	}
	if descriptor.variadic && descriptor.convention != .Odin {
		return expression_unsupported(checker, view, scope, node, "Call_Variadic_Convention")
	}
	file := checker.type_checker.files[file_id]
	positional_count := call_positional_count(file, arguments)
	if spread && (!descriptor.variadic || len(arguments) != parameter_count || positional_count != len(arguments)) {
		return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread")
	}
	if !descriptor.variadic && len(arguments) > parameter_count {
		return expression_unsupported(checker, view, scope, node, "Call_Arguments")
	}
	packed := descriptor.variadic && !spread
	variadic_index := procedure.variadic_index
	fixed_count := parameter_count
	if packed { fixed_count = variadic_index }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	names := make([]string, parameter_count, allocator) or_return
	for parameter, index in procedure.parameters {
		names[index] = entity_get(scopes, parameter).name
	}
	slots := make([]Call_Slot, parameter_count, allocator) or_return
	if reason := call_bind_arguments(file, arguments, names, fixed_count, slots); reason != "" {
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
			argument, valid := expression_call_argument(
				checker,
				view,
				scope,
				slots[index].value,
				descriptor.params[index],
				procedure.parameters[index],
				u32(slots[index].position),
			) or_return
			if !valid { return expression_poison(scope), nil }
			call_arguments[index] = argument
			continue
		}
		if packed && index == variadic_index { continue }
		if index >= len(procedure.defaults) { return expression_unsupported(checker, view, scope, node, "Call_Default_Missing") }
		argument := Call_Argument {
			parameter        = procedure.parameters[index],
			evaluation_order = u32(len(arguments) + index),
		}
		default_argument := procedure.defaults[index]
		switch {
		case default_argument.caller_location:
			argument.value = Operand(Expression_Ref{view, node})
			argument.caller_location = true
		case default_argument.caller_expression:
			text := expression_text(file, node)
			if default_argument.caller_expression_target != "" {
				text = ""
				for parameter, target in procedure.parameters {
					if entity_get(scopes, parameter).name != default_argument.caller_expression_target { continue }
					if slots[target].value != 0 { text = expression_text(file, slots[target].value) }
					break
				}
			}
			string_type := types.intern(checker.type_checker.store, types.Type{kind = .String})
			constant, constant_error := constant_pool_intern_string(checker.constants, text, string_type)
			if constant_error != nil {
				expression_constant_failure(checker, file_id, node, constant_error) or_return
				return expression_poison(scope), nil
			}
			argument.value = Operand(constant)
		case default_argument.value != nil:
			argument.value = default_argument.value
		case:
			return expression_unsupported(checker, view, scope, node, "Call_Default_Value")
		}
		call_arguments[index] = argument
	}
	if packed {
		pack_start := min(positional_count, fixed_count)
		order := u32(len(arguments) + fixed_count)
		if pack_start < positional_count { order = u32(pack_start) }
		variadic, valid := expression_variadic_argument(
			checker,
			view,
			scope,
			arguments[pack_start:positional_count],
			procedure.parameters[variadic_index],
			descriptor.params[variadic_index],
			order,
			allocator,
		) or_return
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
) -> (
	argument: Call_Argument,
	valid: bool,
	err: Resolve_Error,
) {
	value := expression_argument(checker, view, scope, value_node, target) or_return
	if value.state == .Invalid { return {}, false, nil }
	conversion := expression_conversion_plan(checker, value.plan)
	if conversion != 0 {
		retained := checker.plans[conversion].(Conversion_Plan)
		retained.source = Operand(Expression_Ref{view, value_node})
		conversion = Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(retained)) or_return
	}
	return Call_Argument{value = Operand(Expression_Ref{view, value_node}), parameter = parameter, conversion = conversion, evaluation_order = order},
		true,
		nil
}

// The trailing arguments of a variadic call become the elements of one slice argument. Non-constant
// elements must already have the element type; constants take it from the parameter at lowering.
@(private = "file")
expression_variadic_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	arguments: []syntax.Node_Index,
	parameter: Entity_Id,
	slice_type: types.Type_Id,
	order: u32,
	allocator: mem.Allocator,
) -> (
	argument: Call_Argument,
	valid: bool,
	err: Resolve_Error,
) {
	element_type := types.get(checker.type_checker.store, slice_type).elem
	elements := make([]Operand, len(arguments), allocator) or_return
	conversions := make([]Plan_Id, len(arguments), allocator) or_return
	for element, index in arguments {
		value := check_expression(checker, view, scope, element, element_type) or_return
		if value.state == .Invalid { return {}, false, nil }
		switch {
		case value.constant != 0:
			elements[index] = Operand(value.constant)
		case expression_conversion_plan(checker, value.plan) != 0:
			elements[index] = Operand(Expression_Ref{view, element})
			conversions[index] = value.plan
		case:
			elements[index] = Operand(Expression_Ref{view, element})
		}
	}
	return Call_Argument {
			parameter = parameter,
			evaluation_order = order,
			variadic_pack = true,
			variadic_elements = elements,
			variadic_conversions = conversions,
		},
		true,
		nil
}

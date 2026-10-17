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
	if len(descriptor.params) != parameter_count || (descriptor.variadic && descriptor.convention != .Odin) {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	if spread && (!descriptor.variadic || len(arguments) != parameter_count) || !descriptor.variadic && len(arguments) > parameter_count {
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	packed := descriptor.variadic && !spread
	fixed_count := parameter_count
	if packed { fixed_count -= 1 }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	call_arguments := make([]Call_Argument, parameter_count, allocator) or_return
	fixed_supplied := min(len(arguments), fixed_count)
	for argument, index in arguments[:fixed_supplied] {
		value := check_expression(checker, view, scope, argument, descriptor.params[index]) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		conversion := expression_conversion_plan(checker, value.plan)
		if conversion != 0 {
			retained := checker.plans[conversion].(Conversion_Plan)
			retained.source = Operand(Expression_Ref{view, argument})
			conversion = Plan_Id(len(checker.plans))
			append(&checker.plans, Plan(retained)) or_return
		}
		call_arguments[index] = Call_Argument {
			value            = Operand(Expression_Ref{view, argument}),
			parameter        = procedure.parameters[index],
			conversion       = conversion,
			evaluation_order = u32(index),
		}
	}
	for index in fixed_supplied ..< fixed_count {
		if index >= len(procedure.defaults) { return expression_failure(checker, view, scope, node, .Unsupported) }
		argument := Call_Argument {
			parameter        = procedure.parameters[index],
			evaluation_order = u32(index),
		}
		default_argument := procedure.defaults[index]
		switch {
		case default_argument.caller_location:
			argument.value = Operand(Expression_Ref{view, node})
			argument.caller_location = true
		case default_argument.caller_expression:
			source := checker.type_checker.files[file_id]
			text := expression_text(source, node)
			if default_argument.caller_expression_target != "" {
				text = ""
				for parameter, position in procedure.parameters {
					if entity_get(scopes, parameter).name != default_argument.caller_expression_target { continue }
					if position < fixed_supplied { text = expression_text(source, arguments[position]) }
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
			return expression_failure(checker, view, scope, node, .Unsupported)
		}
		call_arguments[index] = argument
	}
	if packed {
		variadic, valid := expression_variadic_argument(
			checker,
			view,
			scope,
			arguments[fixed_supplied:],
			procedure.parameters[fixed_count],
			descriptor.params[fixed_count],
			u32(fixed_count),
			allocator,
		) or_return
		if !valid { return expression_poison(scope), nil }
		call_arguments[fixed_count] = variadic
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
	for element, index in arguments {
		value := check_expression(checker, view, scope, element, element_type) or_return
		if value.state == .Invalid { return {}, false, nil }
		switch {
		case value.constant != 0:
			elements[index] = Operand(value.constant)
		case expression_conversion_plan(checker, value.plan) != 0:
			expression_failure(checker, view, scope, element, .Unsupported) or_return
			return {}, false, nil
		case:
			elements[index] = Operand(Expression_Ref{view, element})
		}
	}
	return Call_Argument{parameter = parameter, evaluation_order = order, variadic_pack = true, variadic_elements = elements}, true, nil
}

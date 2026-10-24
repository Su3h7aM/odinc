package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
is_procedure_value :: proc(checker: ^Expression_Checker, type: types.Type_Id) -> bool {
	if type == 0 { return false }
	store := checker.type_checker.store
	return types.get(store, types.resolve_named(store, type)).kind == .Procedure
}

// A call through a procedure value has no entity. Its arguments map to the parameters of the
// value's static procedure type, and a variadic tail packs or spreads as it does for a named procedure.
@(private = "package")
expression_indirect_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	callee_node: syntax.Node_Index,
	callee: Expression_Info,
	arguments: []syntax.Node_Index,
	spread: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if callee.type == types.TYPE_NONE { return expression_missing_operand_type(checker, view, scope, callee_node, callee.mode) }
	descriptor := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, callee.type))^
	allowed, context_error := expression_require_call_context(checker, view, scope, node, descriptor.convention)
	if context_error != nil { return {}, context_error }
	if !allowed { return expression_poison(scope), nil }
	features_allowed, feature_error := check_call_target_features(checker, view, scope, node, callee.type, 0)
	if feature_error != nil { return {}, feature_error }
	if !features_allowed { return expression_poison(scope), nil }
	if descriptor.c_vararg { return expression_unsupported(checker, view, scope, node, "Indirect_Call_Variadic") }
	if descriptor.variadic && descriptor.convention != .Odin && descriptor.convention != .Contextless && descriptor.convention != .C {
		return expression_unsupported(checker, view, scope, node, "Call_Variadic_Convention")
	}
	file := checker.type_checker.files[checker.views[view].file]
	positional_count := call_positional_count(file, arguments)
	variadic_index := len(descriptor.params) - 1
	if spread {
		if !descriptor.variadic {
			return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread")
		}
		if positional_count > len(descriptor.params) {
			return expression_unsupported(checker, view, scope, node, "Call_Variadic_Spread_Arguments")
		}
		if positional_count != len(descriptor.params) {
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
	if !descriptor.variadic && expanded_count > len(descriptor.params) {
		return expression_unsupported(checker, view, scope, node, "Indirect_Call_Arguments")
	}
	packed := descriptor.variadic && !spread
	fixed_count := len(descriptor.params)
	if packed { fixed_count = variadic_index }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	slots := make([]Call_Slot, len(descriptor.params), allocator) or_return
	if reason := call_bind_arguments(file, arguments, descriptor.param_names, fixed_count, slots, expansions); reason != "" {
		return expression_unsupported(checker, view, scope, node, reason)
	}
	if packed && slots[variadic_index].value != 0 {
		if positional_count > fixed_count {
			return expression_unsupported(checker, view, scope, node, "Call_Variadic_Named")
		}
		packed = false
	}
	metadata, metadata_error := expression_procedure_info(checker, descriptor.procedure_info)
	assert(metadata_error == .None)
	defaults: []Default_Argument
	if metadata != nil { defaults = metadata.defaults }
	call_arguments := make([]Call_Argument, len(slots), allocator) or_return
	for slot, index in slots {
		if packed && index == variadic_index { continue }
		argument: Call_Argument
		valid: bool
		if slot.value != 0 {
			any_integer := metadata != nil && .Any_Integer in metadata.parameter_flags[index]
			no_broadcast := metadata != nil && .No_Broadcast in metadata.parameter_flags[index]
			argument, valid = expression_call_slot_argument(
				checker,
				view,
				scope,
				slot,
				expansions,
				descriptor.params[index],
				0,
				any_integer,
				no_broadcast,
			) or_return
			if spread && index == variadic_index { argument.variadic_spread = true }
		} else {
			argument, valid = expression_call_default_argument(
				checker,
				view,
				scope,
				node,
				descriptor.param_names,
				slots,
				default_argument_at(defaults, index),
				0,
				u32(len(arguments) + index),
			) or_return
		}
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
			0,
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
		Plan(Call_Plan{callee = Operand(Expression_Ref{view, callee_node}), arguments = call_arguments, results = results, variadic = packed}),
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

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
// value's static procedure type.
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
	if spread { return expression_unsupported(checker, view, scope, node, "Indirect_Call_Spread") }
	allowed, context_error := expression_require_call_context(checker, view, scope, node, descriptor.convention)
	if context_error != nil { return {}, context_error }
	if !allowed { return expression_poison(scope), nil }
	features_allowed, feature_error := check_call_target_features(checker, view, scope, node, callee.type, 0)
	if feature_error != nil { return {}, feature_error }
	if !features_allowed { return expression_poison(scope), nil }
	if descriptor.variadic { return expression_unsupported(checker, view, scope, node, "Indirect_Call_Variadic") }
	file := checker.type_checker.files[checker.views[view].file]
	positional_count := call_positional_count(file, arguments)
	expansions := call_expansions(checker, view, scope, file, arguments[:positional_count]) or_return
	expanded_count := len(arguments)
	for results in expansions {
		if results != nil { expanded_count += len(results) - 1 }
	}
	if expanded_count > len(descriptor.params) {
		return expression_unsupported(checker, view, scope, node, "Indirect_Call_Arguments")
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	slots := make([]Call_Slot, len(descriptor.params), allocator) or_return
	if reason := call_bind_arguments(file, arguments, descriptor.param_names, len(slots), slots, expansions); reason != "" {
		return expression_unsupported(checker, view, scope, node, reason)
	}
	metadata, metadata_error := expression_procedure_info(checker, descriptor.procedure_info)
	assert(metadata_error == .None)
	defaults: []Default_Argument
	if metadata != nil { defaults = metadata.defaults }
	call_arguments := make([]Call_Argument, len(slots), allocator) or_return
	for slot, index in slots {
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
	results := make([]types.Type_Id, len(descriptor.results), allocator) or_return
	copy(results, descriptor.results)
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Call_Plan{callee = Operand(Expression_Ref{view, callee_node}), arguments = call_arguments, results = results})) or_return
	info = Expression_Info {
		scope = scope,
		state = .Checked,
		plan  = plan,
		mode  = .No_Value,
	}
	if len(results) == 1 { info.type, info.mode = results[0], .Value }
	return info, nil
}

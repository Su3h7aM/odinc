package check

import "core:mem"
import "oc:syntax"
import "oc:types"

// `receiver->field(arguments)` calls the procedure stored in `field`, passing the object that owns the field as the
// first argument. The receiver is evaluated before the arguments, and the remaining arguments bind to the parameters
// after the first one.
@(private = "package")
expression_selector_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	selector_call := syntax.node_payload(file.ast, node, syntax.Selector_Call_Expr)
	call := syntax.node_payload(file.ast, selector_call.call, syntax.Call_Expr)
	selector_node := selector_call.expr
	selector := syntax.node_payload(file.ast, selector_node, syntax.Selector_Expr)
	arguments := syntax.node_list(file.ast, call.args)

	callee := check_expression(checker, view, scope, selector_node) or_return
	if callee.state == .Invalid { return expression_poison(scope), nil }
	if callee.type == types.TYPE_NONE { return expression_missing_operand_type(checker, view, scope, selector_node, callee.mode) }
	if !is_procedure_value(checker, callee.type) { return expression_unsupported(checker, view, scope, node, "Selector_Call_Callee") }
	if callee.plan == 0 || int(callee.plan) >= len(checker.plans) {
		return expression_unsupported(checker, view, scope, node, "Selector_Call_Callee")
	}
	place, is_place := checker.plans[callee.plan].(Place_Plan)
	if !is_place || len(place.path) == 0 { return expression_unsupported(checker, view, scope, node, "Selector_Call_Callee") }
	owner := place.path[len(place.path) - 1].type

	base := check_expression(checker, view, scope, selector.expr) or_return
	if base.state == .Invalid { return expression_poison(scope), nil }
	addressable := place.path[0].indirect || base.mode == .Variable || base.mode == .Context

	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, callee.type))^
	if len(descriptor.params) == 0 { return expression_unsupported(checker, view, scope, node, "Call_Arguments") }
	parameter := descriptor.params[0]
	allocator := mem.dynamic_arena_allocator(&checker.arena)

	first := Call_Argument {
		value    = Operand(Expression_Ref{view, selector.expr}),
		receiver = selector_receiver_form(checker, owner, parameter, addressable),
	}
	if first.receiver == .None {
		if len(place.path) != 1 || types.get(store, types.resolve_named(store, parameter)).kind != .Any {
			value := expression_argument(checker, view, scope, selector.expr, parameter, false) or_return
			if value.state == .Invalid { return expression_poison(scope), nil }
			return expression_unsupported(checker, view, scope, node, "Selector_Call_Receiver")
		}
		// An `any` parameter takes the base as it is, boxed, as official check_call_arguments does for the receiver.
		boxed, valid := expression_call_slot_argument(checker, view, scope, Call_Slot{value = selector.expr}, nil, parameter, 0) or_return
		if !valid { return expression_poison(scope), nil }
		first = boxed
		first.receiver = .Box
	}

	positional_count := call_positional_count(file, arguments)
	expansions := call_expansions(checker, view, scope, file, arguments[:positional_count]) or_return
	expanded_count := len(arguments)
	for results in expansions {
		if results != nil { expanded_count += len(results) - 1 }
	}
	if expanded_count > len(descriptor.params) - 1 {
		return expression_unsupported(checker, view, scope, node, "Selector_Call_Arguments")
	}
	parameter_names := descriptor.param_names[min(1, len(descriptor.param_names)):]
	slots := make([]Call_Slot, len(descriptor.params) - 1, allocator) or_return
	if reason := call_bind_arguments(file, arguments, parameter_names, len(slots), slots, expansions); reason != "" {
		return expression_unsupported(checker, view, scope, node, reason)
	}
	metadata, metadata_error := expression_procedure_info(checker, descriptor.procedure_info)
	assert(metadata_error == .None)
	call_arguments := make([]Call_Argument, len(descriptor.params), allocator) or_return
	call_arguments[0] = first
	for slot, slot_index in slots {
		index := slot_index + 1
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
			if metadata == nil { return expression_unsupported(checker, view, scope, node, "Call_Default_Missing") }
			argument, valid = expression_call_default_argument(
				checker,
				view,
				scope,
				node,
				parameter_names,
				slots,
				metadata.defaults[index],
				0,
				u32(len(arguments) + slot_index),
			) or_return
		}
		if !valid { return expression_poison(scope), nil }
		argument.evaluation_order += 1
		call_arguments[index] = argument
	}
	results := make([]types.Type_Id, len(descriptor.results), allocator) or_return
	copy(results, descriptor.results)
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Call_Plan{callee = Operand(Expression_Ref{view, selector_node}), arguments = call_arguments, results = results})) or_return
	info = Expression_Info {
		scope = scope,
		state = .Checked,
		plan  = plan,
		mode  = .No_Value,
	}
	if len(results) == 1 { info.type, info.mode = results[0], .Value }
	return info, nil
}

// The first parameter takes the owner by value when its type is the owner's, and otherwise by address when it is a
// pointer to the owner or a rawptr and the owner is addressable.
@(private = "file")
selector_receiver_form :: proc(checker: ^Expression_Checker, owner, parameter: types.Type_Id, addressable: bool) -> Receiver_Form {
	store := checker.type_checker.store
	if types.are_identical(store, owner, parameter) { return .Value }
	if !addressable { return .None }
	if types.get(store, types.resolve_named(store, parameter)).kind == .Raw_Pointer { return .Address }
	pointer := types.intern(store, types.Type{kind = .Pointer, elem = owner})
	if types.are_identical(store, pointer, parameter) { return .Address }
	return .None
}

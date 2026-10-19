package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_multiple_assignment :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	left, right: []syntax.Node_Index,
) -> Resolve_Error {
	file := checker.type_checker.files[file_id]
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	destinations := make([]Operand, len(left), allocator) or_return
	targets := make([]types.Type_Id, len(left), allocator) or_return
	values := make([dynamic]Operand, 0, len(left), allocator) or_return
	conversions := make([dynamic]Plan_Id, 0, len(left), allocator) or_return
	for target, index in left {
		if expression_text(file, target) == "_" {
			destinations[index] = Operand(Entity_Id(0))
			continue
		}
		destination := check_expression(checker, view, scope, target) or_return
		if destination.state == .Invalid { return nil }
		if !expression_assignable(checker, destination) {
			expression_unsupported(checker, view, scope, target, "Assign_Destination_Mode") or_return
			return nil
		}
		if assigns_named_result_in_defer(checker, destination, .Eq) {
			expression_unsupported(checker, view, scope, target, "Assign_Deferred_Result") or_return
			return nil
		}
		destinations[index] = Operand(Expression_Ref{view, target})
		targets[index] = destination.type
	}
	for source in right {
		hint: types.Type_Id
		if len(values) < len(targets) && (file.ast.nodes[source].kind == .Implicit_Selector_Expr || file.ast.nodes[source].kind == .Comp_Lit) {
			hint = targets[len(values)]
		}
		value := check_expression(checker, view, scope, source, hint) or_return
		if value.state == .Invalid { return nil }
		results: []types.Type_Id
		if value.plan != 0 {
			#partial switch plan in checker.plans[value.plan] {
			case Call_Plan:
				results = plan.results
			case Builtin_Plan:
				results = plan.results
			}
		}
		if value_type, is_pair := comma_ok_value_type(checker, value, len(left) - len(values) == 2); is_pair {
			for result_index in 0 ..< 2 {
				result_type := value_type if result_index == 0 else checker.boolean
				target := targets[len(values)]
				if target != 0 && target != result_type {
					converted := expression_conversion(
						checker,
						view,
						scope,
						source,
						Operand(Projection{Expression_Ref{view, source}, u32(result_index)}),
						Expression_Info{type = result_type, mode = .Value, scope = scope, state = .Checked},
						target,
						.Assignment,
					) or_return
					if converted.state == .Invalid { return nil }
					append(&conversions, converted.plan) or_return
				} else {
					append(&conversions, Plan_Id(0)) or_return
				}
				append(&values, Operand(Projection{Expression_Ref{view, source}, u32(result_index)})) or_return
			}
			continue
		}
		if len(results) > 1 && value.mode != .Optional_Ok {
			for result, index in results {
				if len(values) >= len(left) {
					expression_unsupported(checker, view, scope, node, "Assign_Arity") or_return
					return nil
				}
				operand := Operand(Projection{Expression_Ref{view, source}, u32(index)})
				conversion: Plan_Id
				if target := targets[len(values)]; target != 0 {
					converted := expression_conversion(
						checker,
						view,
						scope,
						source,
						operand,
						Expression_Info{type = result, mode = .Value, scope = scope, state = .Checked},
						target,
						.Assignment,
					) or_return
					if converted.state == .Invalid { return nil }
					conversion = converted.plan
				}
				append(&values, operand) or_return
				append(&conversions, conversion) or_return
			}
			continue
		}
		if len(values) >= len(left) {
			expression_unsupported(checker, view, scope, node, "Assign_Arity") or_return
			return nil
		}
		if value.mode == .No_Value || value.mode == .Type || value.mode == .Builtin || value.mode == .Procedure_Group {
			expression_unsupported(checker, view, scope, source, "Assign_Value_Mode") or_return
			return nil
		}
		if value.mode == .Optional_Ok && len(results) > 1 {
			operand := Operand(Projection{Expression_Ref{view, source}, 0})
			if target := targets[len(values)]; target != 0 && target != results[0] {
				converted := expression_conversion(
					checker,
					view,
					scope,
					source,
					operand,
					Expression_Info{type = results[0], mode = .Value, scope = scope, state = .Checked},
					target,
					.Assignment,
				) or_return
				if converted.state == .Invalid { return nil }
				append(&conversions, converted.plan) or_return
			} else {
				append(&conversions, Plan_Id(0)) or_return
			}
			append(&values, operand) or_return
			continue
		}
		target := targets[len(values)]
		if target == 0 { target = types.default_type_of_untyped(checker.type_checker.store, value.type) }
		if target != 0 { value = check_expression(checker, view, scope, source, target) or_return }
		if value.state == .Invalid { return nil }
		append(&values, Operand(Expression_Ref{view, source})) or_return
		append(&conversions, expression_conversion_plan(checker, value.plan)) or_return
	}
	if len(values) != len(left) || len(left) == 0 {
		expression_unsupported(checker, view, scope, node, "Assign_Arity") or_return
		return nil
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Assignment_Plan{destinations = destinations, values = values[:], conversions = conversions[:]})) or_return
	expression_store(checker, view, node, Expression_Info{scope = scope, state = .Checked, plan = plan})
	return nil
}

// Marks a type assertion or map index as its two-result comma-ok form when `pair` is true. Returns the type of its value result.
@(private = "package")
comma_ok_value_type :: proc(checker: ^Expression_Checker, info: Expression_Info, pair: bool) -> (value_type: types.Type_Id, ok: bool) {
	if !pair || info.plan == 0 { return 0, false }
	#partial switch plan in checker.plans[info.plan] {
	case Type_Assertion_Plan:
		assertion := plan
		assertion.comma_ok = true
		checker.plans[info.plan] = Plan(assertion)
		return assertion.target_type, true
	case Map_Index_Plan:
		if info.mode != .Map_Index { return 0, false }
		indexed := plan
		indexed.comma_ok = true
		checker.plans[info.plan] = Plan(indexed)
		return info.type, true
	}
	return 0, false
}

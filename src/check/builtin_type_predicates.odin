package check

import "oc:syntax"
import "oc:types"

// Type predicates of base:intrinsics. Most answer with a constant bool; the base and core queries answer with a type.
@(private = "package")
expression_type_predicate :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	operand := type_query_operand(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	if operand.mode != .Type { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	store := checker.type_checker.store
	#partial switch kind {
	case .Type_Base_Type:
		return Expression_Info{type = types.resolve_named(store, operand.type), mode = .Type, scope = scope, state = .Checked}, nil
	case .Type_Core_Type:
		return Expression_Info{type = types.core_type(store, operand.type), mode = .Type, scope = scope, state = .Checked}, nil
	}
	result: bool
	#partial switch kind {
	case .Type_Comparable:
		result = types.is_comparable(store, operand.type)
	case .Type_Ordered:
		result = types.is_ordered(store, operand.type)
	case .Type_Ordered_Numeric:
		result = types.is_ordered_numeric(store, operand.type)
	case .Type_Simple_Compare:
		result = types.is_simple_compare(store, operand.type)
	case .Type_Enumerated_Array:
		result = types.is_enumerated_array(store, operand.type)
	}
	constant, failure := constant_pool_intern_bool(checker.constants, result, types.TYPE_UNTYPED_BOOL)
	if failure != nil {
		expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = types.TYPE_UNTYPED_BOOL, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

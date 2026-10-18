package check

import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_saturating :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 2 || ellipsis { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	left := check_expression(checker, view, scope, arguments[0]) or_return
	right := check_expression(checker, view, scope, arguments[1], left.type) or_return
	if left.state == .Invalid || right.state == .Invalid { return expression_poison(scope), nil }
	store := checker.type_checker.store
	if conversion_untyped(types.get(store, left.type).kind) {
		left = check_expression(checker, view, scope, arguments[0], right.type) or_return
	}
	descriptor := types.get(store, types.resolve_named(store, left.type))
	if (descriptor.kind != .Integer && descriptor.kind != .Rune) || right.type != left.type || descriptor.endianness == .Big {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	if left.mode == .Constant && right.mode == .Constant {
		constant, failure := constant_saturating(checker.constants, kind, left, right, descriptor^)
		if failure != nil {
			expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = left.type, mode = .Constant, constant = constant, scope = scope, state = .Checked}, nil
	}
	operands := make([]Operand, 2, mem.dynamic_arena_allocator(&checker.arena)) or_return
	for argument, index in arguments { operands[index] = Expression_Ref{view, argument} }
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = left.type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "file")
constant_saturating :: proc(
	pool: ^Constant_Pool,
	kind: Builtin_Kind,
	left, right: Expression_Info,
	descriptor: types.Type,
) -> (
	constant: Const_Id,
	err: Constant_Error,
) {
	left_value := constant_pool_get(pool, left.constant).value.(big.Int)
	right_value := constant_pool_get(pool, right.constant).value.(big.Int)
	value, minimum, maximum: big.Int
	defer big.destroy(&value)
	defer big.destroy(&minimum)
	defer big.destroy(&maximum)
	if kind == .Saturating_Add {big.int_add(&value, &left_value, &right_value) or_return
	} else { big.int_sub(&value, &left_value, &right_value) or_return }
	bits := int(descriptor.count * 8)
	if descriptor.signed { bits -= 1 }
	big.power_of_two(&maximum, bits) or_return
	if descriptor.signed {big.int_neg(&minimum, &maximum) or_return
	} else { big.set(&minimum, 0) or_return }
	big.int_sub_digit(&maximum, &maximum, 1) or_return
	below := big.int_cmp(&value, &minimum) or_return
	above := big.int_cmp(&value, &maximum) or_return
	if below < 0 { return constant_pool_intern_integer(pool, &minimum, left.type) }
	if above > 0 { return constant_pool_intern_integer(pool, &maximum, left.type) }
	return constant_pool_intern_integer(pool, &value, left.type)
}

package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

// `element in set` over a bit_set. Only constant operands fold; a runtime membership test is not supported yet.
@(private = "package")
expression_membership :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	negated: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	binary := syntax.node_payload(file.ast, node, syntax.Binary_Expr)
	store := checker.type_checker.store
	set := check_expression(checker, view, scope, binary.right) or_return
	if set.state == .Invalid { return expression_poison(scope), nil }
	descriptor := types.get(store, types.resolve_named(store, set.type))
	if descriptor.kind != .Bit_Set { return expression_failure(checker, view, scope, node, .Invalid_Operator) }
	element := check_expression(checker, view, scope, binary.left, descriptor.elem) or_return
	if element.state == .Invalid { return expression_poison(scope), nil }
	if set.mode != .Constant || element.mode != .Constant { return expression_unsupported(checker, view, scope, node, "Membership_Runtime") }
	member_value, member_ok := constant_pool_get(checker.constants, element.constant).value.(big.Int)
	set_value, set_ok := constant_pool_get(checker.constants, set.constant).value.(big.Int)
	if !member_ok || !set_ok { return expression_unsupported(checker, view, scope, node, "Membership_Constant") }
	member_integer, integer_error := big.int_get_i64(&member_value)
	if integer_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, integer_error) or_return
		return expression_poison(scope), nil
	}
	offset := int(member_integer - descriptor.lower_bound)
	if offset < 0 || i64(offset) > descriptor.upper_bound - descriptor.lower_bound {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	bit, bit_error := big.int_bitfield_extract_single(&set_value, offset)
	if bit_error == big.Error.Invalid_Argument {
		// Bits beyond the stored limbs are zero.
		bit, bit_error = 0, nil
	}
	if bit_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, bit_error) or_return
		return expression_poison(scope), nil
	}
	found := bit != 0
	if negated { found = !found }
	constant, constant_error := constant_pool_intern_bool(checker.constants, found, checker.boolean)
	if constant_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = checker.boolean, mode = .Constant, constant = constant, scope = scope, state = .Checked}, nil
}

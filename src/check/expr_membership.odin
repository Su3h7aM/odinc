package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

// `element in set` over a bit_set or a map key. Constant bit_set operands fold; other operands yield a runtime bool.
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
	descriptor := types.get(store, types.resolve_named(store, set.type))^
	if descriptor.kind == .Map {
		key := check_expression(checker, view, scope, binary.left, descriptor.index) or_return
		if key.state == .Invalid { return expression_poison(scope), nil }
		if !generator_supported(store, descriptor.index) {
			return expression_unsupported(checker, view, scope, node, "Map_Info_Key")
		}
		_, helper_error := expression_resolve_map_helpers(checker)
		if helper_error != nil { return {}, helper_error }
		append(&checker.plans, Plan(Map_Info_Plan{type = types.resolve_named(store, set.type)})) or_return
		return expression_membership_value(checker, scope), nil
	}
	if descriptor.kind != .Bit_Set { return expression_failure(checker, view, scope, node, .Invalid_Operator) }
	element := check_expression(checker, view, scope, binary.left, descriptor.elem) or_return
	if element.state == .Invalid { return expression_poison(scope), nil }
	if set.mode != .Constant || element.mode != .Constant { return expression_membership_value(checker, scope), nil }
	member_value, member_ok := constant_pool_get(checker.constants, element.constant).value.(big.Int)
	set_value, set_ok := constant_pool_get(checker.constants, set.constant).value.(big.Int)
	if !member_ok || !set_ok { return expression_unsupported(checker, view, scope, node, "Membership_Constant") }
	member_wide, integer_error := big.int_get_i128(&member_value)
	if integer_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, integer_error) or_return
		return expression_poison(scope), nil
	}
	offset_wide := member_wide - descriptor.enum_lower_bound
	if offset_wide < 0 || offset_wide > descriptor.enum_upper_bound - descriptor.enum_lower_bound {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	offset := int(offset_wide)

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

@(private = "file")
expression_membership_value :: proc(checker: ^Expression_Checker, scope: Scope_Id) -> Expression_Info {
	return Expression_Info{type = checker.boolean, mode = .Value, scope = scope, state = .Checked}
}

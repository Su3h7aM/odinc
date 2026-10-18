package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_composite_bit_set :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	type: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file_id := checker.views[view].file
	file := checker.type_checker.files[file_id]
	descriptor := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, type))^
	literal := syntax.node_payload(file.ast, node, syntax.Comp_Lit)
	bits, one, bit: big.Int
	defer big.int_destroy(&bits, &one, &bit)
	constant_error := big.int_set_from_integer(&one, 1)
	if constant_error != nil {
		expression_constant_failure(checker, file_id, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	for element in syntax.node_list(file.ast, literal.elems) {
		value := check_expression(checker, view, scope, element, descriptor.elem) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		if value.constant == 0 { return expression_unsupported(checker, view, scope, node, "Composite_Bit_Set_Runtime") }
		integer := constant_pool_get(checker.constants, value.constant).value.(big.Int)
		index, index_error := big.int_get_i64(&integer)
		if index_error != .None || index < descriptor.lower_bound || index > descriptor.upper_bound {
			return expression_failure(checker, view, scope, element, .Invalid_Operand)
		}
		constant_error = big.int_shl(&bit, &one, int(index - descriptor.lower_bound))
		if constant_error == nil { constant_error = big.bit_or(&bits, &bits, &bit) }
		if constant_error != nil {
			expression_constant_failure(checker, file_id, node, constant_error) or_return
			return expression_poison(scope), nil
		}
	}
	constant, intern_error := constant_pool_intern_integer(checker.constants, &bits, type)
	if intern_error != nil {
		expression_constant_failure(checker, file_id, node, intern_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

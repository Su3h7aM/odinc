package check

import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

Bit_Set_Literal_Plan :: struct {
	type:   types.Type_Id,
	values: []Operand,
}

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
	elements := syntax.node_list(file.ast, literal.elems)
	runtime_value := false
	for element in elements {
		value := check_expression(checker, view, scope, element, descriptor.elem) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		if value.constant == 0 {
			runtime_value = true
			continue
		}
		integer := constant_pool_get(checker.constants, value.constant).value.(big.Int)
		index, index_error := big.int_get_i128(&integer)
		offset := index - descriptor.enum_lower_bound
		if index_error != .None || offset < 0 || offset > descriptor.enum_upper_bound - descriptor.enum_lower_bound {
			return expression_failure(checker, view, scope, element, .Invalid_Operand)
		}
		constant_error = big.int_shl(&bit, &one, int(offset))
		if constant_error == nil { constant_error = big.bit_or(&bits, &bits, &bit) }
		if constant_error != nil {
			expression_constant_failure(checker, file_id, node, constant_error) or_return
			return expression_poison(scope), nil
		}
	}
	if runtime_value {
		values := make([]Operand, len(elements), mem.dynamic_arena_allocator(&checker.arena)) or_return
		for element, index in elements { values[index] = Operand(Expression_Ref{view, element}) }
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Bit_Set_Literal_Plan{type = type, values = values})) or_return
		return Expression_Info{type = type, plan = plan, mode = .Value, scope = scope, state = .Checked}, nil
	}
	constant, intern_error := constant_pool_intern_integer(checker.constants, &bits, type)
	if intern_error != nil {
		expression_constant_failure(checker, file_id, node, intern_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

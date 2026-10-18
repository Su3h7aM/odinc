package check

import "core:math/big"
import "core:mem"
import "core:slice"
import "oc:syntax"
import "oc:types"

// Positional and named (`field = value`) elements become operands in declaration order of the plan's field indices.
@(private = "package")
expression_composite :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	literal := syntax.node_payload(file.ast, node, syntax.Comp_Lit)
	type := hint
	if literal.type != 0 {
		type = type_expression(checker.type_checker, file_id, scope, literal.type, true) or_return
	}
	if type == 0 { return expression_unsupported(checker, view, scope, node, "Composite_Implicit_Type") }
	if type == types.TYPE_POISON { return expression_poison(scope), nil }
	store := checker.type_checker.store
	owner := types.resolve_named(store, type)
	descriptor := types.get(store, owner)^
	if descriptor.kind == .Bit_Set { return expression_composite_bit_set(checker, view, scope, node, type) }
	is_array := descriptor.kind == .Array || descriptor.kind == .Enumerated_Array || descriptor.kind == .Simd_Vector
	if descriptor.kind != .Struct && !is_array {
		reason := "Composite_Type"
		#partial switch descriptor.kind {
		case .Slice:
			reason = "Composite_Slice"
		case .Dynamic_Array:
			reason = "Composite_Dynamic_Array"
		case .Map:
			reason = "Composite_Map"
		}
		return expression_unsupported(checker, view, scope, node, reason)
	}
	fields := descriptor.fields
	elements := syntax.node_list(file.ast, literal.elems)
	if len(elements) > 0 && file.ast.nodes[elements[0]].kind != .Field_Value {
		if descriptor.kind == .Enumerated_Array { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		if descriptor.kind == .Array && i64(len(elements)) != descriptor.count { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	values := make([]Operand, len(elements), allocator) or_return
	indices := make([]u32, len(elements), allocator) or_return
	conversions := make([]Plan_Id, len(elements), allocator) or_return
	count := len(fields)
	if is_array { count = int(descriptor.count) }
	constants := make([]Const_Id, count, allocator) or_return
	seen := make([]bool, count, allocator) or_return
	for element, position in elements {
		value_node := element
		index := position
		if file.ast.nodes[element].kind == .Field_Value {
			pair := syntax.node_payload(file.ast, element, syntax.Field_Value)
			value_node = pair.value
			if is_array {
				key := check_expression(
					checker,
					view,
					scope,
					pair.field,
					descriptor.index if descriptor.kind == .Enumerated_Array else checker.default_integer,
				) or_return
				if key.state == .Invalid { return expression_poison(scope), nil }
				if key.constant == 0 { return expression_failure(checker, view, scope, pair.field, .Invalid_Operand) }
				integer := constant_pool_get(checker.constants, key.constant).value.(big.Int)
				key_value, key_error := big.int_get_i64(&integer)
				if key_error != .None { return expression_failure(checker, view, scope, pair.field, .Invalid_Operand) }
				index = int(key_value - descriptor.lower_bound)
			} else {
				index = struct_field_index(fields, expression_text(file, pair.field))
			}
			if index < 0 { return expression_failure(checker, view, scope, pair.field, .Undeclared_Name) }
		} else if position >= count {
			return expression_failure(checker, view, scope, element, .Invalid_Operand)
		}
		if index < 0 || index >= count || seen[index] { return expression_failure(checker, view, scope, element, .Invalid_Operand) }
		seen[index] = true
		element_type := descriptor.elem
		if !is_array { element_type = fields[index].type }
		value := check_expression(checker, view, scope, value_node, element_type) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		values[position] = Operand(Expression_Ref{view, value_node})
		indices[position] = u32(index)
		conversions[position] = expression_boxing_plan(checker, value.plan)
		if value.constant != 0 && expression_conversion_plan(checker, value.plan) == 0 { constants[index] = value.constant }
	}
	if len(elements) == count && !slice.contains(constants, 0) {
		constant, constant_error := constant_pool_intern_aggregate(checker.constants, type, constants)
		if constant_error != nil {
			expression_constant_failure(checker, file_id, node, constant_error) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Aggregate_Plan{type = type, values = values, field_indices = indices, conversions = conversions})) or_return
	return Expression_Info{type = type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

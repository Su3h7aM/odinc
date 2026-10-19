package check

import "core:mem"
import "core:slice"
import "oc:syntax"
import "oc:types"

// An inferred `[?]T` takes its length from the largest index, so a range key may pass the element count.
@(private = "file")
expression_inferred_length :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file_id: File_Id,
	elements: []syntax.Node_Index,
) -> (
	length: i64,
	failed: bool,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	length = i64(len(elements))
	for element in elements {
		if file.ast.nodes[element].kind != .Field_Value { continue }
		pair := syntax.node_payload(file.ast, element, syntax.Field_Value)
		_, last, key_failed, key_error := expression_array_key(checker, view, scope, file_id, pair.field, checker.default_integer)
		if key_error != nil { return 0, false, key_error }
		if key_failed { return 0, true, nil }
		length = max(length, last + 1)
	}
	return length, false, nil
}

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
		literal_type := literal.type
		for file.ast.nodes[literal_type].kind == .Paren_Expr {
			literal_type = syntax.node_payload(file.ast, literal_type, syntax.Paren_Expr).expr
		}
		if file.ast.nodes[literal_type].kind == .Array_Type {
			array := syntax.node_payload(file.ast, literal_type, syntax.Array_Type)
			length := array.len
			for length != 0 && file.ast.nodes[length].kind == .Paren_Expr {
				length = syntax.node_payload(file.ast, length, syntax.Paren_Expr).expr
			}
			if length != 0 && file.ast.nodes[length].kind == .Unary_Expr && syntax.node_payload(file.ast, length, syntax.Unary_Expr).op.kind == .Question {
				element := type_expression(checker.type_checker, file_id, scope, array.elem, true) or_return
				if element == types.TYPE_POISON { return expression_poison(scope), nil }
				inferred_length, length_failed, length_error := expression_inferred_length(
					checker,
					view,
					scope,
					file_id,
					syntax.node_list(file.ast, literal.elems),
				)
				if length_error != nil { return {}, length_error }
				if length_failed { return expression_poison(scope), nil }
				type = types.intern(checker.type_checker.store, types.Type{kind = .Array, elem = element, count = inferred_length})
			} else {
				type = type_expression(checker.type_checker, file_id, scope, literal.type, true) or_return
			}
		} else {
			type = type_expression(checker.type_checker, file_id, scope, literal.type, true) or_return
		}
	}
	if type == 0 { return expression_unsupported(checker, view, scope, node, "Composite_Implicit_Type") }
	if type == types.TYPE_POISON { return expression_poison(scope), nil }
	store := checker.type_checker.store
	owner := types.resolve_named(store, type)
	descriptor := types.get(store, owner)^
	if descriptor.kind == .Bit_Set { return expression_composite_bit_set(checker, view, scope, node, type) }
	if descriptor.kind == .Slice { return expression_slice_literal(checker, view, file_id, scope, node, type, descriptor.elem) }
	is_array := descriptor.kind == .Array || descriptor.kind == .Enumerated_Array || descriptor.kind == .Simd_Vector
	if len(syntax.node_list(file.ast, literal.elems)) == 0 && expression_zero_fill_supported(checker, store, type) {
		zero, zero_error := expression_zero_fill_constants(checker, store, type)
		if zero_error == nil {
			return Expression_Info{type = type, constant = zero, mode = .Constant, scope = scope, state = .Checked}, nil
		}
	}
	if descriptor.kind != .Struct && descriptor.kind != .Bit_Field && descriptor.kind != .Any && !is_array {
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
	if descriptor.kind == .Any {
		fields = []types.Type_Field {
			{name = "data", type = types.intern(store, types.Type{kind = .Raw_Pointer})},
			{name = "id", type = types.intern(store, types.Type{kind = .Type_Id})},
		}
	}
	elements := syntax.node_list(file.ast, literal.elems)
	if is_array {
		if descriptor.kind == .Array && i64(len(elements)) != descriptor.count && len(elements) > 0 && file.ast.nodes[elements[0]].kind != .Field_Value {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		if descriptor.kind == .Enumerated_Array &&
		   !descriptor.sparse &&
		   descriptor.count > 0 &&
		   i64(len(elements)) < descriptor.count &&
		   len(elements) > 0 &&
		   file.ast.nodes[elements[0]].kind != .Field_Value {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
	}
	if len(elements) > 0 && file.ast.nodes[elements[0]].kind != .Field_Value {
		if descriptor.kind == .Enumerated_Array { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		if descriptor.kind == .Array && i64(len(elements)) != descriptor.count { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	values := make([dynamic]Operand, allocator) or_return
	indices := make([dynamic]u32, allocator) or_return
	conversions := make([dynamic]Plan_Id, allocator) or_return
	count := len(fields)
	if is_array { count = int(descriptor.count) }
	constants := make([]Const_Id, count, allocator) or_return
	seen := make([]bool, count, allocator) or_return
	for element, position in elements {
		value_node := element
		first, last := position, position
		if file.ast.nodes[element].kind == .Field_Value {
			pair := syntax.node_payload(file.ast, element, syntax.Field_Value)
			value_node = pair.value
			if is_array {
				lower_index, upper_index, key_failed, key_error := expression_array_key(
					checker,
					view,
					scope,
					file_id,
					pair.field,
					descriptor.index if descriptor.kind == .Enumerated_Array else checker.default_integer,
				)
				if key_error != nil { return {}, key_error }
				if key_failed { return expression_poison(scope), nil }
				first = int(lower_index - descriptor.lower_bound)
				last = int(upper_index - descriptor.lower_bound)
			} else {
				first = struct_field_index(fields, expression_text(file, pair.field))
				last = first
			}
			if first < 0 { return expression_failure(checker, view, scope, pair.field, .Undeclared_Name) }
		} else if position >= count {
			return expression_failure(checker, view, scope, element, .Invalid_Operand)
		}
		if first < 0 || last >= count { return expression_failure(checker, view, scope, element, .Invalid_Operand) }
		for index in first ..= last {
			if seen[index] { return expression_failure(checker, view, scope, element, .Invalid_Operand) }
			seen[index] = true
		}
		element_type := descriptor.elem
		if !is_array { element_type = fields[first].type }
		value := check_expression(checker, view, scope, value_node, element_type) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		value_operand := Operand(Expression_Ref{view, value_node})
		conversion := expression_boxing_plan(checker, value.plan)
		constant_element := value.constant != 0 && expression_constant_element(checker, store, is_array, element_type, value.plan)
		for index in first ..= last {
			append(&values, value_operand) or_return
			append(&indices, u32(index)) or_return
			append(&conversions, conversion) or_return
			if constant_element { constants[index] = value.constant }
		}
	}
	for _, index in constants {
		if seen[index] { continue }
		element_type := descriptor.elem
		if !is_array { element_type = fields[index].type }
		if !expression_zero_fill_supported(checker, store, element_type) { continue }
		zero, fill_error := expression_zero_fill_constants(checker, store, element_type)
		if fill_error == nil { constants[index] = zero }
	}
	if count > 0 && descriptor.kind != .Bit_Field && descriptor.kind != .Any && !slice.contains(constants, 0) {
		constant, constant_error := constant_pool_intern_aggregate(checker.constants, type, constants)
		if constant_error != nil {
			expression_constant_failure(checker, file_id, node, constant_error) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Aggregate_Plan{type = type, values = values[:], field_indices = indices[:], conversions = conversions[:]})) or_return
	return Expression_Info{type = type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

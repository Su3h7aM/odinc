package check

import "core:fmt"
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
	if len(syntax.node_list(file.ast, literal.elems)) == 0 && expression_zero_fill_supported(checker, store, type) {
		zero, zero_error := expression_zero_fill_constants(checker, store, type)
		if zero_error == nil {
			return Expression_Info{type = type, constant = zero, mode = .Constant, scope = scope, state = .Checked}, nil
		}
	}
	if descriptor.kind == .Struct && descriptor.soa != .None {
		if descriptor.soa != .Fixed {
			reason := "#soa slices and dynamic arrays are not supported for compound literals"
			if literal.type != 0 {
				literal_type := type_unparen(file, literal.type)
				#partial switch file.ast.nodes[literal_type].kind {
				case .Array_Type:
					if syntax.node_payload(file.ast, literal_type, syntax.Array_Type).tag != 0 {
						reason = "#soa slices are not supported for compound literals"
					}
				case .Dynamic_Array_Type:
					if syntax.node_payload(file.ast, literal_type, syntax.Dynamic_Array_Type).tag != 0 {
						reason = "#soa dynamic arrays are not supported for compound literals"
					}
				}
			}
			return expression_failure(checker, view, scope, node, .Invalid_Operand, reason)
		}
		return expression_composite_soa_fixed(checker, view, file_id, scope, node, type)
	}
	is_array := descriptor.kind == .Array || descriptor.kind == .Enumerated_Array || descriptor.kind == .Simd_Vector
	is_matrix := descriptor.kind == .Matrix
	if descriptor.kind == .Union && len(syntax.node_list(file.ast, literal.elems)) == 0 {
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Aggregate_Plan{type = type})) or_return
		return Expression_Info{type = type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	if descriptor.kind == .Union && literal.type == 0 {
		return expression_union_variant_literal(checker, view, file_id, scope, node, descriptor.variants)
	}
	if descriptor.kind != .Struct && descriptor.kind != .Bit_Field && descriptor.kind != .Any && !is_array && !is_matrix {
		if descriptor.kind == .Dynamic_Array || descriptor.kind == .Map {
			return expression_dynamic_literal(checker, view, file_id, scope, node, type, descriptor)
		}
		if descriptor.kind == .Fixed_Capacity_Array {
			return expression_fixed_capacity_literal(checker, view, file_id, scope, node, type, syntax.node_list(file.ast, literal.elems), descriptor)
		}
		reason := "Composite_Type"
		#partial switch descriptor.kind {
		case .Slice:
			reason = "Composite_Slice"
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
	if is_matrix {
		// Official keys are logical row-major flat indices, so keyed literals may be sparse and zero-fill.
		has_keyed := false
		for element in elements {
			if file.ast.nodes[element].kind == .Field_Value {
				has_keyed = true
				break
			}
		}
		if !has_keyed && len(elements) > 0 && i64(len(elements)) != descriptor.count * descriptor.upper_bound {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
	}
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
	paths := make([dynamic][]Member_Step, allocator) or_return
	has_raw_union := descriptor.raw_union
	conversions := make([dynamic]Plan_Id, allocator) or_return
	count := len(fields)
	if is_array { count = int(descriptor.count) }
	if is_matrix { count = int(descriptor.count * descriptor.upper_bound) }
	constants := make([]Const_Id, count, allocator) or_return
	seen := make([]bool, count, allocator) or_return
	for element, position in elements {
		value_node := element
		first, last := position, position
		path := make([dynamic]Member_Step, allocator) or_return
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
				if is_matrix {
					lower_index, upper_index, key_failed, key_error := expression_array_key(checker, view, scope, file_id, pair.field, checker.default_integer)
					if key_error != nil { return {}, key_error }
					if key_failed { return expression_poison(scope), nil }
					first = int(lower_index)
					last = int(upper_index)
				} else {
					if descriptor.kind == .Struct {
						if _, found := field_path(checker, owner, false, expression_text(file, pair.field), &path); !found {
							return expression_unknown_field(checker, view, scope, file, pair.field)
						}
						first = int(path[0].field_index)
					} else {
						first = struct_field_index(fields, expression_text(file, pair.field))
					}
					last = first
				}
			}
			if first < 0 { return expression_unknown_field(checker, view, scope, file, pair.field) }
		} else if position >= count {
			return expression_failure(checker, view, scope, element, .Invalid_Operand)
		}
		matrix_keyed := is_matrix && file.ast.nodes[element].kind == .Field_Value
		if is_matrix && !matrix_keyed {
			first = matrix_storage_index(descriptor, position)
			last = first
		}
		if first < 0 || last >= count { return expression_failure(checker, view, scope, element, .Invalid_Operand) }
		previously_seen := seen[first]
		if descriptor.kind == .Struct {
			if len(path) == 0 { append(&path, Member_Step{type = owner, field_index = u32(first)}) or_return }
			for previous in paths {
				if expression_composite_paths_overlap(store, previous, path[:]) {
					return expression_failure(checker, view, scope, element, .Invalid_Operand)
				}
			}
			for step in path { has_raw_union ||= types.get(store, step.type).raw_union }
		}
		for index in first ..= last {
			physical := index
			if matrix_keyed { physical = matrix_storage_index(descriptor, index) }
			if descriptor.kind != .Struct && seen[physical] { return expression_failure(checker, view, scope, element, .Invalid_Operand) }
			seen[physical] = true
		}
		element_type := descriptor.elem
		if !is_array && !is_matrix { element_type = fields[first].type }
		if len(path) > 1 {
			last_step := path[len(path) - 1]
			element_type = types.get(store, last_step.type).fields[last_step.field_index].type
		}
		value := check_expression(checker, view, scope, value_node, element_type) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		if value.mode == .Type {
			if descriptor.kind == .Struct && file.ast.nodes[element].kind == .Field_Value {
				_, failure := expression_type_context_failure(checker, view, scope, value_node, element_type, value.type, "a structure literal")
				return expression_poison(scope), failure
			}
			expression_type_ambiguous_failure(checker, view, scope, value_node) or_return
			return expression_poison(scope), nil
		}
		value_operand := Operand(Expression_Ref{view, value_node})
		conversion := expression_boxing_plan(checker, value.plan)
		constant_element := value.constant != 0 && expression_constant_element(checker, store, is_array || is_matrix, element_type, value.plan)
		variant, variant_error := expression_union_variant_value(checker, element_type, value)
		if variant_error != nil {
			expression_constant_failure(checker, file_id, node, variant_error) or_return
			return expression_poison(scope), nil
		}
		for index in first ..= last {
			physical := index
			if matrix_keyed { physical = matrix_storage_index(descriptor, index) }
			append(&values, value_operand) or_return
			append(&indices, u32(physical)) or_return
			append(&paths, path[:]) or_return
			append(&conversions, conversion) or_return
			constant := variant
			if constant_element { constant = value.constant }
			if len(path) > 1 {
				updated: Const_Id
				failure: Constant_Error
				if constants[physical] != 0 || !previously_seen {
					updated, failure = expression_composite_insert_constant(checker, constants[physical], fields[physical].type, path[1:], constant)
				}
				if failure != nil {
					expression_constant_failure(checker, file_id, node, failure) or_return
					return expression_poison(scope), nil
				}
				constants[physical] = updated
			} else {
				constants[physical] = constant
			}
		}
	}
	for _, index in constants {
		if seen[index] { continue }
		element_type := descriptor.elem
		if !is_array && !is_matrix { element_type = fields[index].type }
		if !expression_zero_fill_supported(checker, store, element_type) { continue }
		zero, fill_error := expression_zero_fill_constants(checker, store, element_type)
		if fill_error == nil { constants[index] = zero }
	}
	if count > 0 && !has_raw_union && descriptor.kind != .Bit_Field && descriptor.kind != .Any && !slice.contains(constants, 0) {
		constant, constant_error := constant_pool_intern_aggregate(checker.constants, type, constants)
		if constant_error != nil {
			expression_constant_failure(checker, file_id, node, constant_error) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
	}
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(Aggregate_Plan{type = type, values = values[:], field_indices = indices[:], field_paths = paths[:], conversions = conversions[:]}),
	) or_return
	return Expression_Info{type = type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "file")
// An untyped literal against a union takes the one variant it fits, as upstream check_compound_literal does.
expression_union_variant_literal :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	variants: []types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	fitting: [dynamic]types.Type_Id
	defer delete(fitting)
	for variant in variants {
		mark := expression_speculation_begin(checker)
		trial, trial_error := expression_composite(checker, view, file_id, scope, node, variant)
		fits :=
			trial_error == nil &&
			trial.state != .Invalid &&
			len(checker.diagnostics) == mark.checker_diagnostics &&
			len(checker.type_checker.diagnostics) == mark.type_diagnostics
		expression_speculation_end(checker, mark)
		if trial_error != nil { return {}, trial_error }
		if fits { append(&fitting, variant) or_return }
	}
	switch len(fitting) {
	case 0:
		return expression_failure(checker, view, scope, node, .Invalid_Operand, "No variant of the union matches this compound literal")
	case 1:
		return expression_composite(checker, view, file_id, scope, node, fitting[0])
	}
	return expression_failure(checker, view, scope, node, .Invalid_Operand, "Ambiguous compound literal for the union; it matches more than one variant")
}

expression_composite_paths_overlap :: proc(store: ^types.Store, left, right: []Member_Step) -> bool {
	for step, index in left {
		if index >= len(right) { return false }
		if step.field_index != right[index].field_index {
			return types.get(store, step.type).raw_union
		}
	}
	return len(left) == len(right)
}

@(private = "file")
expression_composite_insert_constant :: proc(
	checker: ^Expression_Checker,
	original: Const_Id,
	type: types.Type_Id,
	path: []Member_Step,
	value: Const_Id,
) -> (
	result: Const_Id,
	err: Constant_Error,
) {
	if value == 0 { return 0, nil }
	if len(path) == 0 { return value, nil }
	store := checker.type_checker.store
	original := original
	if original == 0 {
		if !expression_zero_fill_supported(checker, store, type) { return 0, nil }
		zero, failure := expression_zero_fill_constants(checker, store, type)
		if failure != nil { return 0, failure }
		original = zero
	}
	aggregate, ok := constant_pool_get(checker.constants, original).value.(Aggregate_Value)
	if !ok { return 0, nil }
	elements := make([]Const_Id, len(aggregate.elements), checker.allocator) or_return
	defer delete(elements, checker.allocator)
	copy(elements, aggregate.elements)
	index := path[0].field_index
	field_type := types.get(store, path[0].type).fields[index].type
	elements[index] = expression_composite_insert_constant(checker, elements[index], field_type, path[1:], value) or_return
	if elements[index] == 0 { return 0, nil }
	constant, failure := constant_pool_intern_aggregate(checker.constants, type, elements)
	if failure != nil { return 0, failure }
	return constant, nil
}

// A fixed `#soa[N]T` literal lists element values row by row, like an array
// literal over the element type (check_expr.cpp), not column values over the
// spread struct. Rows are checked against the element type and transposed
// into the spread columns, so the stored constant and plan stay column-wise.
@(private = "file")
expression_composite_soa_fixed :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	type: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	literal := syntax.node_payload(file.ast, node, syntax.Comp_Lit)
	store := checker.type_checker.store
	owner := types.resolve_named(store, type)
	descriptor := types.get(store, owner)
	count := int(descriptor.count)
	elem := descriptor.soa_elem
	elements := syntax.node_list(file.ast, literal.elems)
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	values := make([dynamic]Operand, allocator) or_return
	indices := make([dynamic]u32, allocator) or_return
	conversions := make([dynamic]Plan_Id, allocator) or_return
	rows := make([]Const_Id, count, allocator) or_return
	seen := make([]bool, count, allocator) or_return
	all_constant := true
	for element, position in elements {
		value_node := element
		first, last := position, position
		if file.ast.nodes[element].kind == .Field_Value {
			pair := syntax.node_payload(file.ast, element, syntax.Field_Value)
			value_node = pair.value
			lower_index, upper_index, key_failed, key_error := expression_array_key(checker, view, scope, file_id, pair.field, checker.default_integer)
			if key_error != nil { return {}, key_error }
			if key_failed { return expression_poison(scope), nil }
			first, last = int(lower_index), int(upper_index)
		} else if position >= count {
			return expression_failure(checker, view, scope, element, .Invalid_Operand)
		}
		if first < 0 || last >= count { return expression_failure(checker, view, scope, element, .Invalid_Operand) }
		for index in first ..= last {
			if seen[index] { return expression_failure(checker, view, scope, element, .Invalid_Operand) }
			seen[index] = true
		}
		value := check_expression(checker, view, scope, value_node, elem) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		if value.mode == .Type {
			expression_type_ambiguous_failure(checker, view, scope, value_node) or_return
			return expression_poison(scope), nil
		}
		value_operand := Operand(Expression_Ref{view, value_node})
		conversion := expression_boxing_plan(checker, value.plan)
		constant := value.constant
		if conversion != 0 || constant == 0 || !expression_constant_element(checker, store, true, elem, value.plan) {
			constant = 0
		}
		if constant == 0 { all_constant = false }
		variant, variant_error := expression_union_variant_value(checker, elem, value)
		if variant_error != nil {
			expression_constant_failure(checker, file_id, node, variant_error) or_return
			return expression_poison(scope), nil
		}
		if variant != 0 { constant = variant }
		for index in first ..= last {
			append(&values, value_operand) or_return
			append(&indices, u32(index)) or_return
			append(&conversions, conversion) or_return
			rows[index] = constant
		}
	}
	for index in 0 ..< count {
		if seen[index] { continue }
		if !expression_zero_fill_supported(checker, store, elem) {
			all_constant = false
			continue
		}
		zero, fill_error := expression_zero_fill_constants(checker, store, elem)
		if fill_error != nil {
			expression_constant_failure(checker, file_id, node, fill_error) or_return
			return expression_poison(scope), nil
		}
		rows[index] = zero
	}
	if all_constant {
		core := types.get(store, types.core_type(store, elem))
		spread := len(core.fields) if core.kind == .Struct else int(core.count)
		columns := make([]Const_Id, len(descriptor.fields), allocator) or_return
		transposed := true
		for field in 0 ..< spread {
			cells := make([]Const_Id, count, allocator) or_return
			for row in 0 ..< count {
				aggregate, is_aggregate := constant_pool_get(checker.constants, rows[row]).value.(Aggregate_Value)
				if !is_aggregate || field >= len(aggregate.elements) {
					transposed = false
					break
				}
				cells[row] = aggregate.elements[field]
			}
			if !transposed { break }
			column, column_error := constant_pool_intern_aggregate(checker.constants, descriptor.fields[field].type, cells)
			if column_error != nil {
				expression_constant_failure(checker, file_id, node, column_error) or_return
				return expression_poison(scope), nil
			}
			columns[field] = column
		}
		if transposed {
			constant, constant_error := constant_pool_intern_aggregate(checker.constants, type, columns)
			if constant_error != nil {
				expression_constant_failure(checker, file_id, node, constant_error) or_return
				return expression_poison(scope), nil
			}
			return Expression_Info{type = type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
		}
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Aggregate_Plan{type = type, values = values[:], field_indices = indices[:], conversions = conversions[:]})) or_return
	return Expression_Info{type = type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "file")
expression_unknown_field :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file: ^File,
	field: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	reason := fmt.aprintf("Unknown field '%s' in structure literal", expression_text(file, field), allocator = mem.dynamic_arena_allocator(&checker.arena))
	return expression_failure(checker, view, scope, field, .Undeclared_Name, reason)
}

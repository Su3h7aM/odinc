package check

import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

// Indexing an array or slice. Constant indexes into an array are checked against its length here and need no
// runtime check; other indexes keep a Bounds_Plan whose policy follows the file, and #no_bounds_check disables it.
@(private = "package")
expression_index :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	access := syntax.node_payload(file.ast, node, syntax.Index_Expr)
	base := check_expression(checker, view, scope, access.expr) or_return
	if base.state == .Invalid { return expression_poison(scope), nil }
	if base.type == types.TYPE_NONE { return expression_missing_operand_type(checker, view, scope, access.expr, base.mode) }
	store := checker.type_checker.store
	base_descriptor := types.get(store, types.resolve_named(store, base.type))
	is_pointer := base_descriptor.kind == .Pointer
	map_type := base.type if !is_pointer else base_descriptor.elem
	if is_pointer { base_descriptor = types.get(store, types.resolve_named(store, base_descriptor.elem)) }
	if base_descriptor.kind == .Map {
		if !generator_supported(store, base_descriptor.index) {
			return expression_unsupported(checker, view, scope, access.expr, "Map_Info_Key")
		}
		_, helper_error := expression_resolve_map_helpers(checker)
		if helper_error != nil { return {}, helper_error }
		writable := base.mode == .Variable || is_pointer
		append(&checker.plans, Plan(Map_Info_Plan{type = types.resolve_named(store, map_type)})) or_return
		return expression_map_index(checker, view, scope, access.expr, access.index, base_descriptor.index, base_descriptor.elem, writable)
	}
	_, _, is_soa := soa_descriptor(store, map_type)
	if is_soa {
		return expression_soa_index(checker, view, file_id, scope, node, base, is_pointer)
	}
	if base.mode == .Soa_Variable {
		return expression_soa_component_index(checker, view, file_id, scope, node, base)
	}
	is_array := base_descriptor.kind == .Array
	is_dynamic_array := base_descriptor.kind == .Dynamic_Array
	is_enumerated_array := base_descriptor.kind == .Enumerated_Array
	is_string := base_descriptor.kind == .String || base_descriptor.kind == .String16
	is_multi_pointer := base_descriptor.kind == .Multi_Pointer
	if base_descriptor.kind == .Matrix {
		vector := expression_matrix_vector(checker, view, file_id, scope, node, base) or_return
		return vector, nil
	}
	if !is_array && !is_dynamic_array && !is_enumerated_array && !is_string && !is_multi_pointer && base_descriptor.kind != .Slice {
		return expression_unsupported(checker, view, scope, node, "Index_Base")
	}
	length := base_descriptor.count
	element_type := base_descriptor.elem
	mode := Addressing_Mode.Variable
	if is_array && !is_pointer && base.mode != .Variable {
		mode = .Value
	}
	if is_string {
		element_width: i64 = 1 if base_descriptor.kind == .String else 2
		element_type = types.sized_integer(checker.type_checker.store, element_width, false)
		mode = .Value
	}
	position_hint := types.TYPE_NONE
	if is_enumerated_array {
		position_hint = base_descriptor.index
	}
	position := check_expression(checker, view, scope, access.index, position_hint) or_return
	if position.state == .Invalid { return expression_poison(scope), nil }
	if conversion_untyped(types.get(checker.type_checker.store, position.type).kind) {
		position = check_expression(checker, view, scope, access.index, checker.default_integer) or_return
	}
	statically_checked := false
	if is_array && position.mode == .Constant {
		value := constant_pool_get(checker.constants, position.constant).value.(big.Int)
		constant_index, value_error := big.int_get_i64(&value)
		if value_error != .None || constant_index < 0 || constant_index >= length {
			return expression_failure(checker, view, scope, access.index, .Invalid_Operand)
		}
		statically_checked = true
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, 2, allocator) or_return
	operands[0] = Operand(Expression_Ref{view, access.expr})
	operands[1] = Operand(Expression_Ref{view, access.index})
	policy := Check_Policy.Disabled if checker.unchecked_depth > 0 || statically_checked else Check_Policy.Enabled
	if checker.type_checker.files[file_id].policy.bounds_check == .Disabled || is_multi_pointer { policy = .Disabled }
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Bounds_Plan{kind = .Index, operands = operands, policy = policy})) or_return
	return Expression_Info{type = element_type, mode = mode, plan = plan, scope = scope, state = .Checked}, nil
}

// Slicing an addressable array or any slice yields a slice header. An absent bound is a nil operand; lowering
// supplies 0 for low and the length for high.
@(private = "package")
expression_slice :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	access := syntax.node_payload(file.ast, node, syntax.Slice_Expr)
	base := check_expression(checker, view, scope, access.expr) or_return
	if base.state == .Invalid { return expression_poison(scope), nil }
	if base.type == types.TYPE_NONE { return expression_missing_operand_type(checker, view, scope, access.expr, base.mode) }
	store := checker.type_checker.store
	base_descriptor := types.get(store, types.resolve_named(store, base.type))
	has_pointer_base := base_descriptor.kind == .Pointer
	if has_pointer_base {
		base.type = base_descriptor.elem
		base_descriptor = types.get(store, types.resolve_named(store, base_descriptor.elem))
	}
	_, _, is_soa := soa_descriptor(store, base.type)
	if is_soa {
		return expression_soa_slice(checker, view, file_id, scope, node, base)
	}
	is_multi_pointer := base_descriptor.kind == .Multi_Pointer
	is_string := base_descriptor.kind == .String || base_descriptor.kind == .String16
	if (base_descriptor.kind != .Array || base.mode != .Variable) &&
	   base_descriptor.kind != .Slice &&
	   !is_multi_pointer &&
	   !is_string &&
	   base_descriptor.kind != .Dynamic_Array {
		return expression_unsupported(checker, view, scope, node, "Slice_Base")
	}
	slice_type := types.intern(store, types.Type{kind = .Slice, elem = base_descriptor.elem})
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, 3, allocator) or_return
	operands[0] = Operand(Expression_Ref{view, access.expr})
	bounds := [2]syntax.Node_Index{access.low, access.high}
	for bound, index in bounds {
		if bound == 0 { continue }
		position := check_expression(checker, view, scope, bound) or_return
		if position.state == .Invalid { return expression_poison(scope), nil }
		if conversion_untyped(types.get(store, position.type).kind) {
			_ = check_expression(checker, view, scope, bound, checker.default_integer) or_return
		}
		operands[index + 1] = Operand(Expression_Ref{view, bound})
	}
	policy := Check_Policy.Disabled if checker.unchecked_depth > 0 else Check_Policy.Enabled
	if file.policy.bounds_check == .Disabled { policy = .Disabled }
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Bounds_Plan{kind = .Slice, operands = operands, policy = policy})) or_return
	// ptr[low:] is ptr + low and keeps the multi-pointer type; ptr[low:high] yields a slice.
	result_type := slice_type
	if is_string || (is_multi_pointer && access.high == 0) { result_type = base.type }
	return Expression_Info{type = result_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

Map_Index_Plan :: struct {
	map_value: Operand,
	key:       Operand,
	comma_ok:  bool,
	writable:  bool,
}

// An element is assignable when its map is a variable or a pointer, as check_stmt.cpp:543-560 requires.
@(private = "package")
expression_assignable :: proc(checker: ^Expression_Checker, info: Expression_Info) -> bool {
	#partial switch info.mode {
	case .Variable, .Context:
		return true
	case .Soa_Variable, .Soa_Pointer:
		return true
	case .Map_Index:
		plan, is_map := checker.plans[info.plan].(Map_Index_Plan)
		return is_map && plan.writable
	}
	return false
}

// Map indexing yields the element with mode .Map_Index. Its key takes the key type as a hint, as official check_expr.cpp:13034-13047 does.
@(private = "file")
expression_map_index :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	map_node, key_node: syntax.Node_Index,
	key_type, value_type: types.Type_Id,
	writable: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	key := check_expression(checker, view, scope, key_node, key_type) or_return
	if key.state == .Invalid { return expression_poison(scope), nil }
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(Map_Index_Plan{map_value = Operand(Expression_Ref{view, map_node}), key = Operand(Expression_Ref{view, key_node}), writable = writable}),
	) or_return
	return Expression_Info{type = value_type, mode = .Map_Index, plan = plan, scope = scope, state = .Checked}, nil
}

// Temporary stubs while the real #soa element access lands; they keep the tree compiling.
// The number of spread fields of an #soa element: the struct fields, or the
// array components. Matches the official complete_soa_type field splitting.
@(private = "package")
soa_spread_count :: proc(store: ^types.Store, elem: types.Type_Id) -> int {
	core := types.get(store, types.core_type(store, elem))
	#partial switch core.kind {
	case .Struct:
		return len(core.fields)
	case .Array:
		return int(core.count)
	}
	return 0
}

// The element type of spread field k: the struct field type, or the array
// element type. Fixed #soa stores [N] of it per field, slices store [^] of it.
@(private = "package")
soa_field_element :: proc(store: ^types.Store, soa: types.Type_Id, field: int) -> (types.Type_Id, bool) {
	descriptor := types.get(store, soa)
	if field < 0 || field >= len(descriptor.fields) { return types.TYPE_NONE, false }
	field_type := types.get(store, types.resolve_named(store, descriptor.fields[field].type))
	if field_type.kind != .Array && field_type.kind != .Multi_Pointer { return types.TYPE_NONE, false }
	return field_type.elem, true
}

// A Place_Plan selecting spread field k of an #soa container, as `soa.x` does.
// Hidden length and capacity fields are not spread fields and never match.
@(private = "package")
soa_place_field :: proc(store: ^types.Store, plan: Place_Plan, soa: types.Type_Id) -> (field: int, ok: bool) {
	if len(plan.path) != 1 { return 0, false }
	step := plan.path[0]
	if types.resolve_named(store, step.type) != soa { return 0, false }
	descriptor := types.get(store, soa)
	if int(step.field_index) >= soa_spread_count(store, descriptor.soa_elem) { return 0, false }
	return int(step.field_index), true
}

// Bounds-check policy for one #soa index: disabled without checks, by file
// policy, or once the index is proven in range at compile time.
@(private = "package")
soa_index_policy :: proc(checker: ^Expression_Checker, file_id: File_Id, static_ok: bool) -> Check_Policy {
	if checker.unchecked_depth > 0 || static_ok { return .Disabled }
	if checker.type_checker.files[file_id].policy.bounds_check == .Disabled { return .Disabled }
	return .Enabled
}

// Checks one #soa index expression. A fixed #soa proves a constant index
// against N here; anything else traps at runtime through the plan policy.
// Only integers index an #soa container (check_index_value, check_expr.cpp).
@(private = "file")
soa_check_index :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file_id: File_Id,
	node: syntax.Node_Index,
	length: i64,
	fixed: bool,
) -> (
	static_ok: bool,
	index: Expression_Info,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	position := check_expression(checker, view, scope, node) or_return
	if position.state == .Invalid {
		failed := expression_poison(scope)
		return false, failed, nil
	}
	if conversion_untyped(types.get(store, position.type).kind) {
		position = check_expression(checker, view, scope, node, checker.default_integer) or_return
		if position.state == .Invalid {
			failed := expression_poison(scope)
			return false, failed, nil
		}
	}
	kind := types.get(store, types.resolve_named(store, position.type)).kind
	if kind != .Integer && kind != .Rune {
		failed, fail_err := expression_failure(checker, view, scope, node, .Invalid_Operand)
		if fail_err != nil { return false, failed, fail_err }
		return false, failed, nil
	}
	if position.mode == .Constant && position.constant != 0 {
		integer := constant_pool_get(checker.constants, position.constant).value.(big.Int)
		index_value, value_error := big.int_get_i64(&integer)
		if value_error != .None || index_value < 0 {
			failed, fail_err := expression_failure(checker, view, scope, node, .Invalid_Operand)
			if fail_err != nil { return false, failed, fail_err }
			return false, failed, nil
		}
		if fixed {
			if index_value >= length {
				failed, fail_err := expression_failure(checker, view, scope, node, .Invalid_Operand)
				if fail_err != nil { return false, failed, fail_err }
				return false, failed, nil
			}
			return true, position, nil
		}
	}
	return false, position, nil
}

// Interns a constant spread-field index for a Soa_Plan.
@(private = "file")
soa_const_field :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file_id: File_Id,
	node: syntax.Node_Index,
	field: int,
) -> (
	operand: Operand,
	err: Resolve_Error,
) {
	value: big.Int
	defer big.destroy(&value)
	if set_error := big.set(&value, i64(field)); set_error != nil {
		expression_constant_failure(checker, file_id, node, set_error) or_return
		return nil, nil
	}
	field_id, intern_error := constant_pool_intern_integer(checker.constants, &value, types.TYPE_UNTYPED_INTEGER)
	if intern_error != nil {
		expression_constant_failure(checker, file_id, node, intern_error) or_return
		return nil, nil
	}
	return Operand(field_id), nil
}

// `s[i][j]`: the element is itself an array, so the second index selects a
// component. Reached from expression_index because the base type is the
// element array rather than the #soa container.
@(private = "package")
expression_soa_component_index :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	base: Expression_Info,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	access := syntax.node_payload(file.ast, node, syntax.Index_Expr)
	store := checker.type_checker.store
	base_plan, is_soa_plan := checker.plans[base.plan].(Soa_Plan)
	if !is_soa_plan || base_plan.field != nil {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	descriptor := types.get(store, base_plan.soa)
	core := types.get(store, types.core_type(store, descriptor.soa_elem))
	if core.kind != .Array { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	component_static, position := soa_check_index(checker, view, scope, file_id, access.index, core.count, true) or_return
	if position.state == .Invalid { return expression_poison(scope), nil }
	field: Operand
	if position.mode == .Constant && position.constant != 0 {
		integer := constant_pool_get(checker.constants, position.constant).value.(big.Int)
		if component, value_error := big.int_get_i64(&integer); value_error == .None {
			field = soa_const_field(checker, view, scope, file_id, node, int(component)) or_return
		}
	}
	if field == nil { field = Operand(Expression_Ref{view, access.index}) }
	policy := base_plan.policy
	if !component_static { policy = soa_index_policy(checker, file_id, false) }
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(Soa_Plan{container = base_plan.container, index = base_plan.index, field = field, soa = base_plan.soa, policy = policy}),
	) or_return
	return Expression_Info{type = core.elem, mode = .Variable, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "package")
expression_soa_index :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	base: Expression_Info,
	is_pointer: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	access := syntax.node_payload(file.ast, node, syntax.Index_Expr)
	store := checker.type_checker.store
	map_type := base.type
	if is_pointer {
		map_type = types.get(store, types.resolve_named(store, base.type)).elem
	}
	soa, descriptor, _ := soa_descriptor(store, map_type)
	elem := descriptor.soa_elem
	fixed := descriptor.soa == .Fixed

	// `s.x[i]`: the base names one spread field of the container.
	if base.plan != 0 {
		if place, is_place := checker.plans[base.plan].(Place_Plan); is_place {
			if spread, is_spread := soa_place_field(store, place, soa); is_spread {
				element, found := soa_field_element(store, soa, spread)
				if !found { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
				static_ok, position := soa_check_index(checker, view, scope, file_id, access.index, 0, fixed) or_return
				if position.state == .Invalid { return expression_poison(scope), nil }
				field := soa_const_field(checker, view, scope, file_id, node, spread) or_return
				plan := Plan_Id(len(checker.plans))
				append(
					&checker.plans,
					Plan(
						Soa_Plan {
							container = place.root,
							index = Operand(Expression_Ref{view, access.index}),
							field = field,
							soa = soa,
							policy = soa_index_policy(checker, file_id, static_ok),
						},
					),
				) or_return
				return Expression_Info{type = element, mode = .Variable, plan = plan, scope = scope, state = .Checked}, nil
			}
		}
	}

	length := descriptor.count
	static_ok, position := soa_check_index(checker, view, scope, file_id, access.index, length, fixed) or_return
	if position.state == .Invalid { return expression_poison(scope), nil }
	mode := Addressing_Mode.Value
	if base.mode == .Variable || is_pointer { mode = .Soa_Variable }
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(
			Soa_Plan {
				container = Operand(Expression_Ref{view, access.expr}),
				index = Operand(Expression_Ref{view, access.index}),
				soa = soa,
				policy = soa_index_policy(checker, file_id, static_ok),
			},
		),
	) or_return
	return Expression_Info{type = elem, mode = mode, plan = plan, scope = scope, state = .Checked}, nil
}

// Slicing an #soa container yields an #soa slice whose field pointers are the
// offset fields of the source, with the hidden length adjusted. Slicing a
// fixed #soa needs an addressable value, as the official check_slice_expr does.
@(private = "package")
expression_soa_slice :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	base: Expression_Info,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	access := syntax.node_payload(file.ast, node, syntax.Slice_Expr)
	store := checker.type_checker.store
	was_pointer := types.get(store, types.resolve_named(store, base.type)).kind == .Pointer
	source := base.type
	if was_pointer { source = types.get(store, types.resolve_named(store, base.type)).elem }
	soa, descriptor, _ := soa_descriptor(store, source)
	if descriptor.soa == .Fixed && base.mode != .Variable && !was_pointer {
		return expression_unsupported(checker, view, scope, node, "Slice_Base")
	}
	slice, valid := soa_struct(checker.type_checker, descriptor.soa_elem, 0, .Slice)
	if !valid { return expression_unsupported(checker, view, scope, node, "Soa_Slice") }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, 3, allocator) or_return
	operands[0] = Operand(Expression_Ref{view, access.expr})
	bounds := [2]syntax.Node_Index{access.low, access.high}
	for bound, index in bounds {
		if bound == 0 { continue }
		position := check_expression(checker, view, scope, bound) or_return
		if position.state == .Invalid { return expression_poison(scope), nil }
		if conversion_untyped(types.get(store, position.type).kind) {
			_ = check_expression(checker, view, scope, bound, checker.default_integer) or_return
		}
		operands[index + 1] = Operand(Expression_Ref{view, bound})
	}
	policy := Check_Policy.Disabled if checker.unchecked_depth > 0 else Check_Policy.Enabled
	if file.policy.bounds_check == .Disabled { policy = .Disabled }
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Bounds_Plan{kind = .Soa, operands = operands, policy = policy})) or_return
	_ = soa
	return Expression_Info{type = slice, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// len and cap of an #soa container for the builtins dispatch: a fixed #soa
// answers its constant count for both (probed official), a slice answers len
// at runtime, and a dynamic answers len and cap at runtime from its hidden fields.
@(private = "package")
expression_soa_length :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	operand: Expression_Info,
	argument: syntax.Node_Index,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, operand.type))
	if descriptor.kind == .Pointer {
		descriptor = types.get(store, types.resolve_named(store, descriptor.elem))
	}
	if operand.mode == .Type || descriptor.kind != .Struct || descriptor.soa == .None {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	if descriptor.soa == .Fixed {
		value: big.Int
		defer big.destroy(&value)
		if set_error := big.set(&value, descriptor.count); set_error != nil {
			expression_constant_failure(checker, checker.views[view].file, node, set_error) or_return
			return expression_poison(scope), nil
		}
		constant, constant_error := constant_pool_intern_integer(checker.constants, &value, types.TYPE_UNTYPED_INTEGER)
		if constant_error != nil {
			expression_constant_failure(checker, checker.views[view].file, node, constant_error) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = types.TYPE_UNTYPED_INTEGER, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
	}
	if kind == .Cap && descriptor.soa != .Dynamic {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, 1, allocator) or_return
	operands[0] = Operand(Expression_Ref{view, argument})
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	result := checker.default_integer
	if hinted := length_integer_hint(checker, hint); hinted != 0 { result = hinted }
	return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// A selector on an #soa element: `s[i].x` names spread field k, and `s[i].x`
// on an array element names component x/y/z/w. The result has a real address
// (the field element pointer), so its mode is Variable, unlike the scattered
// whole element. A multi-letter swizzle gathers the named lanes instead; the
// lanes live in the spread columns, so it shares the array swizzle rules.
@(private = "package")
expression_soa_field :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	base: Expression_Info,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	selector := syntax.node_payload(file.ast, node, syntax.Selector_Expr)
	name := expression_text(file, selector.field)
	store := checker.type_checker.store
	base_plan, is_soa_plan := checker.plans[base.plan].(Soa_Plan)
	if !is_soa_plan || base_plan.field != nil {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	descriptor := types.get(store, base_plan.soa)
	core := types.get(store, types.core_type(store, descriptor.soa_elem))
	spread := -1
	field_type := types.TYPE_NONE
	if core.kind == .Struct {
		allocator := mem.dynamic_arena_allocator(&checker.arena)
		path := make([dynamic]Member_Step, 0, allocator) or_return
		found_type, found := field_path(checker, types.core_type(store, descriptor.soa_elem), false, name, &path)
		if !found { return expression_failure(checker, view, scope, selector.field, .Undeclared_Name) }
		if len(path) != 1 { return expression_unsupported(checker, view, scope, node, "Soa_Using_Field") }
		spread, field_type = int(path[0].field_index), found_type
	} else if core.kind == .Array {
		if len(name) != 1 {
			element := Expression_Info {
				type  = descriptor.soa_elem,
				mode  = .Variable,
				scope = scope,
				state = .Checked,
			}
			return expression_array_selector(checker, view, file_id, scope, node, element, core^, false, types.TYPE_NONE)
		}
		switch name[0] {
		case 'x', 'r':
			spread = 0
		case 'y', 'g':
			spread = 1
		case 'z', 'b':
			spread = 2
		case 'w', 'a':
			spread = 3
		case:
			return expression_failure(checker, view, scope, selector.field, .Undeclared_Name)
		}
		if i64(spread) >= core.count {
			return expression_failure(checker, view, scope, selector.field, .Undeclared_Name)
		}
		field_type = core.elem
	} else {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	field := soa_const_field(checker, view, scope, file_id, node, spread) or_return
	plan := Plan_Id(len(checker.plans))
	append(
		&checker.plans,
		Plan(Soa_Plan{container = base_plan.container, index = base_plan.index, field = field, soa = base_plan.soa, policy = base_plan.policy}),
	) or_return
	return Expression_Info{type = field_type, mode = .Variable, plan = plan, scope = scope, state = .Checked}, nil
}

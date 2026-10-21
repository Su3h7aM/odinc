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
		return expression_unsupported(checker, view, scope, node, "Soa_Index")
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
		return expression_unsupported(checker, view, scope, node, "Soa_Slice")
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

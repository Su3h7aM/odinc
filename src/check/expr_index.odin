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
	base_descriptor := types.get(checker.type_checker.store, base.type)
	is_array := base_descriptor.kind == .Array
	is_string := base_descriptor.kind == .String || base_descriptor.kind == .String16
	is_multi_pointer := base_descriptor.kind == .Multi_Pointer
	if (!is_array && !is_string && !is_multi_pointer && base_descriptor.kind != .Slice) || (is_array && base.mode != .Variable) {
		return expression_unsupported(checker, view, scope, node, "Index_Base")
	}
	length := base_descriptor.count
	element_type := base_descriptor.elem
	mode := Addressing_Mode.Variable
	if is_string {
		element_width: i64 = 1 if base_descriptor.kind == .String else 2
		element_type = types.intern(checker.type_checker.store, types.Type{kind = .Integer, count = element_width})
		mode = .Value
	}
	position := check_expression(checker, view, scope, access.index) or_return
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
	store := checker.type_checker.store
	base_descriptor := types.get(store, types.resolve_named(store, base.type))
	is_multi_pointer := base_descriptor.kind == .Multi_Pointer
	if (base_descriptor.kind != .Array || base.mode != .Variable) && base_descriptor.kind != .Slice && !is_multi_pointer {
		return expression_unsupported(checker, view, scope, node, "Slice_Base")
	}
	slice_type := types.intern(store, types.Type{kind = .Slice, elem = base_descriptor.elem})
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, 3, allocator) or_return
	operands[0] = Operand(Expression_Ref{view, access.expr})
	bounds := [2]syntax.Node_Index{access.low, access.high}
	for bound, index in bounds {
		if bound == 0 { continue }
		position := check_expression(checker, view, scope, bound, checker.default_integer) or_return
		if position.state == .Invalid { return expression_poison(scope), nil }
		operands[index + 1] = Operand(Expression_Ref{view, bound})
	}
	policy := Check_Policy.Disabled if checker.unchecked_depth > 0 else Check_Policy.Enabled
	if file.policy.bounds_check == .Disabled { policy = .Disabled }
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Bounds_Plan{kind = .Slice, operands = operands, policy = policy})) or_return
	// ptr[low:] is ptr + low and keeps the multi-pointer type; ptr[low:high] yields a slice.
	result_type := slice_type
	if is_multi_pointer && access.high == 0 { result_type = base.type }
	return Expression_Info{type = result_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

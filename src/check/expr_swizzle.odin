package check

import "core:fmt"
import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_array_selector :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	base: Expression_Info,
	descriptor: types.Type,
	indirect: bool,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	selector := syntax.node_payload(file.ast, node, syntax.Selector_Expr)
	name := expression_text(file, selector.field)
	if len(name) == 0 || len(name) > 4 || base.mode == .Type {
		return expression_no_field(checker, view, scope, file, selector, base)
	}
	if len(name) == 1 && descriptor.count > 4 {
		return expression_no_field(checker, view, scope, file, selector, base)
	}
	indices := make([]i64, len(name), mem.dynamic_arena_allocator(&checker.arena)) or_return
	plan := Swizzle_Plan {
		indices  = indices,
		root     = Operand(Expression_Ref{view, selector.expr}),
		count    = len(name),
		indirect = indirect,
	}
	xyzw, rgba := false, false
	for letter, index in name {
		switch letter {
		case 'x', 'r':
			plan.indices[index] = 0
		case 'y', 'g':
			plan.indices[index] = 1
		case 'z', 'b':
			plan.indices[index] = 2
		case 'w', 'a':
			plan.indices[index] = 3
		case:
			return expression_no_field(checker, view, scope, file, selector, base)
		}
		xyzw ||= letter == 'x' || letter == 'y' || letter == 'z' || letter == 'w'
		rgba ||= letter == 'r' || letter == 'g' || letter == 'b' || letter == 'a'
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	if xyzw && rgba {
		reason := fmt.aprintf("Mixture of swizzle kinds for field index, got %s", expression_text(file, selector.expr), allocator = allocator)
		return expression_failure(checker, view, scope, node, .Invalid_Operand, reason)
	}
	for index in 0 ..< len(name) {
		if i64(plan.indices[index]) >= descriptor.count {
			if len(name) == 1 { return expression_no_field(checker, view, scope, file, selector, base) }
			reason := fmt.aprintf("Swizzle value is out of bounds, got %c, max count %d", name[index], descriptor.count, allocator = allocator)
			return expression_failure(checker, view, scope, selector.field, .Invalid_Operand, reason)
		}
	}
	result_type := descriptor.elem
	if len(name) > 1 {
		store := checker.type_checker.store
		result_type = types.intern(store, types.Type{kind = .Array, elem = descriptor.elem, count = i64(len(name))})
		if i64(len(name)) == descriptor.count {
			result_type = base.type
			if indirect { result_type = types.get(store, types.resolve_named(store, base.type)).elem }
		}
		if hint != 0 {
			hint_descriptor := types.get(store, types.resolve_named(store, hint))
			if hint_descriptor.kind == .Array && hint_descriptor.count == i64(len(name)) && hint_descriptor.elem == descriptor.elem {
				result_type = hint
			}
		}
	}
	mode := Addressing_Mode.Value
	if base.mode == .Variable || indirect { mode = .Variable }
	plan_id := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(plan)) or_return
	return Expression_Info{type = result_type, mode = mode, plan = plan_id, scope = scope, state = .Checked}, nil
}


@(private = "package")
expression_swizzle_builtin :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) < 2 {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	base := check_expression(checker, view, scope, arguments[0]) or_return
	if base.state == .Invalid { return expression_poison(scope), nil }
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, base.type))
	if descriptor.kind != .Array && descriptor.kind != .Simd_Vector {
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand)
	}
	count := len(arguments) - 1
	if count < 2 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	if descriptor.kind == .Simd_Vector && ((count & (count - 1)) != 0 || count > 64) {
		return expression_failure(checker, view, scope, node, .Invalid_Operand)
	}
	indices := make([]i64, count, mem.dynamic_arena_allocator(&checker.arena)) or_return
	for i in 0 ..< count {
		value := check_expression(checker, view, scope, arguments[i + 1]) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		if value.mode != .Constant {
			return expression_failure(checker, view, scope, arguments[i + 1], .Invalid_Operand)
		}
		pool_value := constant_pool_get(checker.constants, value.constant)
		if pool_value == nil {
			return expression_failure(checker, view, scope, arguments[i + 1], .Invalid_Operand)
		}
		integer, is_integer := pool_value.value.(big.Int)
		if !is_integer {
			return expression_failure(checker, view, scope, arguments[i + 1], .Invalid_Operand)
		}
		n, index_error := big.int_get_i64(&integer)
		if index_error != .None || n < 0 || n >= descriptor.count {
			return expression_failure(checker, view, scope, arguments[i + 1], .Invalid_Operand)
		}
		indices[i] = n
	}
	plan := Swizzle_Plan {
		root     = Operand(Expression_Ref{view, arguments[0]}),
		indices  = indices,
		count    = count,
		indirect = false,
	}
	result_type := descriptor.elem
	if count > 1 {
		result_type = types.intern(store, types.Type{kind = descriptor.kind, elem = descriptor.elem, count = i64(count)})
		if i64(count) == descriptor.count {
			result_type = base.type
		}
		if hint != 0 {
			hint_descriptor := types.get(store, types.resolve_named(store, hint))
			if hint_descriptor.kind == descriptor.kind && hint_descriptor.count == i64(count) && hint_descriptor.elem == descriptor.elem {
				result_type = hint
			}
		}
	}
	plan_id := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(plan)) or_return
	mode := Addressing_Mode.Value
	if base.mode == .Variable && descriptor.kind == .Array { mode = .Variable }
	return Expression_Info{type = result_type, mode = mode, plan = plan_id, scope = scope, state = .Checked}, nil
}

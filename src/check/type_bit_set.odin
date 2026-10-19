package check

import "oc:syntax"
import "oc:types"

// Without an underlying type a bit_set holds at most 128 bits, as in official check_type.cpp (MAX_BITS).
@(private = "file")
BIT_SET_MAX_BITS :: 128

// `bit_set[E]`, `bit_set[E; U]` over an enum `E`, and `bit_set[lo..=hi]`, `bit_set[lo..<hi]`, `bit_set[lo..=hi; U]` intervals.
bit_set_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	record := syntax.node_payload(file.ast, node, syntax.Bit_Set_Type)
	base := type_unparen(file, record.elem)
	if file.ast.nodes[base].kind == .Binary_Expr {
		interval := syntax.node_payload(file.ast, base, syntax.Binary_Expr)
		if interval.op.kind == .Range_Half || interval.op.kind == .Range_Full || interval.op.kind == .Ellipsis {
			return bit_set_interval_type(checker, file_id, file, scope, node, record, interval, elem_node = base)
		}
	}
	elem := type_expression(checker, file_id, scope, record.elem, false) or_return
	if elem == types.TYPE_POISON { return types.TYPE_POISON, nil }
	store := checker.store
	enum_descriptor := types.get(store, underlying_type(store, elem))
	if enum_descriptor.kind != .Enum {
		type_report(checker, file_id, file, record.elem, .Invalid_Bit_Set_Element) or_return
		return types.TYPE_POISON, nil
	}
	backing := types.TYPE_NONE
	bits := i64(BIT_SET_MAX_BITS)
	lower := enum_descriptor.lower_bound
	if record.underlying != 0 {
		backing = type_expression(checker, file_id, scope, record.underlying, false) or_return
		if backing == types.TYPE_POISON { return types.TYPE_POISON, nil }
		backing_descriptor := types.get(store, underlying_type(store, backing))
		if backing_descriptor.kind != .Integer {
			type_report(checker, file_id, file, record.underlying, .Invalid_Bit_Set_Backing) or_return
			return types.TYPE_POISON, nil
		}
		size, _, _ := types.layout(store, backing)
		bits = 8 * size
		if lower < 0 {
			type_report(checker, file_id, file, record.elem, .Bit_Set_Out_Of_Range) or_return
			return types.TYPE_POISON, nil
		}
		lower = 0
	}
	upper := enum_descriptor.upper_bound
	if upper - lower >= bits {
		type_report(checker, file_id, file, node, .Bit_Set_Out_Of_Range) or_return
		return types.TYPE_POISON, nil
	}
	return types.intern(store, types.Type{kind = .Bit_Set, elem = elem, backing = backing, lower_bound = lower, upper_bound = upper}), nil
}

// Interval `bit_set[lo..=hi]` bounds are constant integers; `..<` excludes the upper bound.
@(private = "file")
bit_set_interval_type :: proc(
	checker: ^Type_Checker,
	file_id: File_Id,
	file: ^File,
	scope: Scope_Id,
	node: syntax.Node_Index,
	record: syntax.Bit_Set_Type,
	interval: syntax.Binary_Expr,
	elem_node: syntax.Node_Index,
) -> (
	type: types.Type_Id,
	err: Resolve_Error,
) {
	store := checker.store
	elem: types.Type_Id
	if defaulted, found, err2 := default_expression_type(checker, scope, file_id, interval.left);
	   found && defaulted != types.TYPE_NONE && defaulted != types.TYPE_POISON {
		if defaulted == types.TYPE_POISON { return types.TYPE_POISON, err2 }
		elem = defaulted
	} else {
		elem = types.intern(store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	}
	lower, lower_ok := integer_expression(checker, file_id, file, scope, interval.left) or_return
	if !lower_ok { return types.TYPE_POISON, nil }
	upper, upper_ok := integer_expression(checker, file_id, file, scope, interval.right) or_return
	if !upper_ok { return types.TYPE_POISON, nil }
	if lower > upper {
		type_report(checker, file_id, file, interval.left, .Bit_Set_Out_Of_Range) or_return
		return types.TYPE_POISON, nil
	}
	backing := types.TYPE_NONE
	bits := i64(BIT_SET_MAX_BITS)
	if record.underlying != 0 {
		backing = type_expression(checker, file_id, scope, record.underlying, false) or_return
		if backing == types.TYPE_POISON { return types.TYPE_POISON, nil }
		backing_descriptor := types.get(store, underlying_type(store, backing))
		if backing_descriptor.kind != .Integer {
			type_report(checker, file_id, file, record.underlying, .Invalid_Bit_Set_Backing) or_return
			return types.TYPE_POISON, nil
		}
		size, _, _ := types.layout(store, backing)
		bits = 8 * size
		if lower < 0 {
			type_report(checker, file_id, file, elem_node, .Bit_Set_Out_Of_Range) or_return
			return types.TYPE_POISON, nil
		}
	}
	inclusive := interval.op.kind != .Range_Half
	if inclusive && upper - lower >= bits {
		type_report(checker, file_id, file, elem_node, .Bit_Set_Out_Of_Range) or_return
		return types.TYPE_POISON, nil
	}
	if !inclusive {
		if upper - lower > bits {
			type_report(checker, file_id, file, elem_node, .Bit_Set_Out_Of_Range) or_return
			return types.TYPE_POISON, nil
		}
		upper -= 1
	}
	return types.intern(store, types.Type{kind = .Bit_Set, elem = elem, backing = backing, lower_bound = lower, upper_bound = upper}), nil
}

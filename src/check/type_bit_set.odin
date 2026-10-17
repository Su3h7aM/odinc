package check

import "oc:syntax"
import "oc:types"

// Without an underlying type a bit_set holds at most 128 bits, as in official check_type.cpp (MAX_BITS).
@(private = "file")
BIT_SET_MAX_BITS :: 128

// `bit_set[E]` and `bit_set[E; U]` over an enum `E`. Intervals `bit_set[lo..=hi]` are not supported yet.
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

package check

import "oc:syntax"
import "oc:types"

// Default argument promotion of one C variadic tail value, as official c_vararg_promote_type
// (types.cpp:3635-3675). Endianness variants keep their byte order. Bit sets promote as their backing.
c_vararg_promoted_type :: proc(store: ^types.Store, type_id: types.Type_Id) -> types.Type_Id {
	core := types.core_type(store, type_id)
	descriptor := types.get(store, core)
	#partial switch descriptor.kind {
	case .Bit_Set:
		return c_vararg_promoted_type(store, descriptor.backing)
	case .Untyped_Integer:
		return types.default_type_of_untyped(store, core)
	case .Untyped_Float:
		return types.intern(store, types.Type{kind = .Float, count = 8})
	case .Untyped_Bool, .Bool:
		return types.intern(store, types.Type{kind = .Integer, name = "i32", count = 4, signed = true})
	case .Untyped_Nil:
		return types.intern(store, types.Type{kind = .Raw_Pointer})
	case .Float:
		if descriptor.count <= 4 {
			return types.intern(store, types.Type{kind = .Float, count = 8, endianness = descriptor.endianness})
		}
	case .Integer:
		if descriptor.count <= 2 {
			return types.intern(store, types.Type{kind = .Integer, name = "i32", count = 4, signed = true, endianness = descriptor.endianness})
		}
	}
	return type_id
}

// One C variadic tail value, converted to its promoted type. Untyped constants take the promoted type as their
// target; runtime values convert by cast, since promotion widens and the source type is not assignable to it.
@(private = "package")
expression_c_vararg_argument :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	order: u32,
) -> (
	argument: Call_Argument,
	valid: bool,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	info := check_expression(checker, view, scope, node) or_return
	info = expression_single_value(info)
	if info.state == .Invalid { return {}, false, nil }
	promoted := c_vararg_promoted_type(store, info.type)
	value: Expression_Info
	switch {
	case info.mode == .Constant && types.is_untyped(store, info.type):
		value = expression_argument(checker, view, scope, node, promoted, false) or_return
	case info.type == promoted:
		value = info
	case:
		source := Operand(Expression_Ref{view, node})
		if info.mode == .Constant { source = Operand(info.constant) }
		value = expression_conversion(checker, view, scope, node, source, info, promoted, .Cast) or_return
	}
	if value.state == .Invalid { return {}, false, nil }
	argument = Call_Argument {
		evaluation_order = order,
		promoted_type    = promoted,
	}
	if value.constant != 0 {
		argument.value = Operand(value.constant)
	} else {
		argument.value = Operand(Expression_Ref{view, node})
		argument.conversion = expression_conversion_plan(checker, value.plan)
	}
	return argument, true, nil
}

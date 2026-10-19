package check

import "core:math/big"
import "oc:types"

// Mirrors official is_type_constant_type: such an element keeps an array or simd literal constant.
@(private = "file")
expression_constant_type :: proc(store: ^types.Store, type: types.Type_Id) -> bool {
	descriptor := types.get(store, conversion_base_type(store, type))^
	#partial switch descriptor.kind {
	case .Bool, .Integer, .Float, .Rune, .Complex, .Quaternion, .String, .String16, .CString, .CString16, .Raw_Pointer, .Type_Id, .Bit_Set, .Procedure:
		return true
	case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
		return expression_constant_type(store, descriptor.elem)
	}
	return false
}

@(private = "package")
expression_constant_element :: proc(checker: ^Expression_Checker, store: ^types.Store, is_array: bool, element_type: types.Type_Id, plan: Plan_Id) -> bool {
	if expression_boxing_plan(checker, plan) != 0 { return false }
	if is_array { return expression_constant_type(store, element_type) }
	return expression_conversion_plan(checker, plan) == 0
}

@(private = "package")
expression_zero_fill_supported :: proc(checker: ^Expression_Checker, store: ^types.Store, element_type: types.Type_Id) -> bool {
	descriptor := types.get(store, types.resolve_named(store, element_type))^
	#partial switch descriptor.kind {
	case .Bool, .Integer, .Rune, .String, .String16:
		return true
	case .Enum:
		return true
	}
	return false
}

@(private = "package")
expression_zero_fill_constants :: proc(
	checker: ^Expression_Checker,
	store: ^types.Store,
	element_type := types.TYPE_NONE,
) -> (
	id: Const_Id,
	err: Constant_Error,
) {
	descriptor := types.get(store, types.resolve_named(store, element_type))^
	#partial switch descriptor.kind {
	case .Bool:
		return constant_pool_intern_bool(checker.constants, false, element_type)
	case .Integer, .Rune, .Enum:
		zero: big.Int
		defer big.destroy(&zero)
		if set_error := big.int_set_from_integer(&zero, 0); set_error != nil {
			return 0, set_error
		}
		result, intern_error := constant_pool_intern_integer(checker.constants, &zero, element_type)
		return result, intern_error
	case .String:
		return constant_pool_intern_string(checker.constants, "", element_type)
	case .String16:
		return constant_pool_intern_string16(checker.constants, nil, element_type)
	}
	return 0, Constant_Pool_Error.Invalid_Operand
}

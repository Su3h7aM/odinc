package check

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

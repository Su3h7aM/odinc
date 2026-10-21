package check

import "core:math/big"
import "oc:types"

// Official keys array element constness on the operand mode (check_expr.cpp:10337); enums and structs of constant fields qualify.
@(private = "file")
expression_constant_type :: proc(store: ^types.Store, type: types.Type_Id) -> bool {
	descriptor := types.get(store, conversion_base_type(store, type))^
	#partial switch descriptor.kind {
	case .Bool, .Integer, .Float, .Rune, .Complex, .Quaternion, .String, .String16, .CString, .CString16, .Raw_Pointer, .Type_Id, .Bit_Set, .Procedure, .Enum:
		return true
	case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
		return expression_constant_type(store, descriptor.elem)
	case .Struct:
		for field in descriptor.fields {
			if !expression_constant_type(store, field.type) { return false }
		}
		return true
	}
	return false
}

@(private = "package")
expression_constant_element :: proc(checker: ^Expression_Checker, store: ^types.Store, is_array: bool, element_type: types.Type_Id, plan: Plan_Id) -> bool {
	if expression_boxing_plan(checker, plan) != 0 { return false }
	if is_array { return expression_constant_type(store, element_type) }
	return true
}

@(private = "package")
expression_zero_fill_supported :: proc(checker: ^Expression_Checker, store: ^types.Store, element_type: types.Type_Id) -> bool {
	descriptor := types.get(store, types.resolve_named(store, element_type))^
	#partial switch descriptor.kind {
	case .Bool, .Integer, .Rune, .Float, .String, .String16:
		return true
	case .Enum, .Bit_Set:
		return true
	case .Raw_Pointer, .Pointer, .Multi_Pointer, .CString, .CString16, .Type_Id, .Procedure:
		return true
	case .Union:
		return expression_union_variant_constant(store, element_type)
	case .Array, .Enumerated_Array:
		return expression_zero_fill_supported(checker, store, descriptor.elem)
	case .Struct:
		for field in descriptor.fields {
			if !expression_zero_fill_supported(checker, store, field.type) { return false }
		}
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
	case .Integer, .Rune, .Enum, .Bit_Set:
		zero: big.Int
		defer big.destroy(&zero)
		if set_error := big.int_set_from_integer(&zero, 0); set_error != nil {
			return 0, set_error
		}
		result, intern_error := constant_pool_intern_integer(checker.constants, &zero, element_type)
		return result, intern_error
	case .String:
		return constant_pool_intern_string(checker.constants, "", element_type)
	case .Float:
		return constant_pool_intern_float(checker.constants, Float_Value{width = u8(descriptor.count * 8)}, element_type)
	case .Array, .Enumerated_Array:
		element_ids := make([]Const_Id, int(descriptor.count), checker.allocator) or_return
		defer delete(element_ids, checker.allocator)
		for &element in element_ids {
			element = expression_zero_fill_constants(checker, store, descriptor.elem) or_return
		}
		return constant_pool_intern_aggregate(checker.constants, element_type, element_ids)
	case .Raw_Pointer, .Pointer, .Multi_Pointer, .CString, .CString16, .Type_Id, .Procedure:
		return constant_pool_intern_nil(checker.constants, element_type)
	case .Struct:
		element_ids := make([]Const_Id, len(descriptor.fields), checker.allocator) or_return
		defer delete(element_ids, checker.allocator)
		for field, index in descriptor.fields {
			element_ids[index] = expression_zero_fill_constants(checker, store, field.type) or_return
		}
		return constant_pool_intern_aggregate(checker.constants, element_type, element_ids)
	case .String16:
		return constant_pool_intern_string16(checker.constants, nil, element_type)
	case .Union:
		return constant_pool_intern_nil(checker.constants, element_type)
	}
	return 0, Constant_Pool_Error.Invalid_Operand
}

// Mirrors is_type_constant_type (types.cpp:1522): the basic constant types, bit sets, procedures and their arrays.
@(private = "file")
expression_constant_basic :: proc(store: ^types.Store, type: types.Type_Id) -> bool {
	descriptor := types.get(store, conversion_base_type(store, type))^
	#partial switch descriptor.kind {
	case .Bool, .Integer, .Float, .Rune, .Complex, .Quaternion, .String, .String16, .CString, .CString16, .Raw_Pointer, .Type_Id, .Bit_Set, .Procedure:
		return true
	case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
		return expression_constant_basic(store, descriptor.elem)
	}
	return false
}

// Mirrors is_type_constant_type_for_unions and is_type_union_constantable (types.cpp:2837, 2871): a union is constant
// when every variant is, and structs qualify when every field does.
@(private = "file")
expression_union_variant_constant :: proc(store: ^types.Store, type: types.Type_Id) -> bool {
	descriptor := types.get(store, conversion_base_type(store, type))^
	#partial switch descriptor.kind {
	case .Struct:
		for field in descriptor.fields {
			if !expression_union_variant_constant(store, field.type) { return false }
		}
		return true
	case .Union:
		for variant in descriptor.variants {
			if !expression_union_variant_constant(store, variant) { return false }
		}
		return true
	}
	return expression_constant_basic(store, type)
}

// A field value injected into a constantable union keeps its constant as the union's variant value.
@(private = "package")
expression_union_variant_value :: proc(
	checker: ^Expression_Checker,
	element_type: types.Type_Id,
	value: Expression_Info,
) -> (
	variant: Const_Id,
	err: Constant_Error,
) {
	if value.plan == 0 { return 0, nil }
	conversion, found := checker.plans[value.plan].(Conversion_Plan)
	if !found || conversion.kind != .Union_Injection { return 0, nil }
	source, is_constant := conversion.source.(Const_Id)
	if !is_constant || source == 0 { return 0, nil }
	store := checker.type_checker.store
	if !expression_union_variant_constant(store, element_type) { return 0, nil }
	return constant_pool_intern_variant(checker.constants, element_type, source)
}

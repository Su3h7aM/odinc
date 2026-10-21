package check

import "base:runtime"
import "core:math/big"
import "core:mem"
import "core:strings"
import "oc:syntax"
import "oc:types"

// Declared names of procedures in package base:intrinsics that the checker lowers as builtins.
intrinsic_builtin_kind :: proc(name: string) -> Builtin_Kind {
	switch name {
	case "type_is_array":
		return .Type_Array
	case "type_is_pointer":
		return .Type_Pointer
	case "type_is_struct":
		return .Type_Struct
	case "type_is_slice":
		return .Type_Slice
	case "type_is_integer":
		return .Type_Integer
	case "type_is_float":
		return .Type_Float
	case "type_is_numeric":
		return .Type_Numeric
	case "type_is_unsigned":
		return .Type_Unsigned
	case "type_is_proc":
		return .Type_Proc
	case "type_is_internally_pointer_like":
		return .Type_Internally_Pointer_Like
	case "type_is_boolean":
		return .Type_Boolean
	case "type_is_multi_pointer":
		return .Type_Multi_Pointer
	case "type_is_dynamic_array":
		return .Type_Dynamic_Array
	case "type_is_map":
		return .Type_Map
	case "type_is_union":
		return .Type_Union
	case "type_is_enum":
		return .Type_Enum
	case "type_is_bit_set":
		return .Type_Bit_Set
	case "type_struct_field_count":
		return .Type_Struct_Field_Count
	case "type_has_field":
		return .Type_Has_Field
	case "type_field_type":
		return .Type_Field_Type
	case "type_bit_set_underlying_type":
		return .Type_Bit_Set_Underlying_Type
	case "type_elem_type":
		return .Type_Elem_Type
	case "type_map_info":
		return .Type_Map_Info
	case "type_map_cell_info":
		return .Type_Map_Cell_Info
	case "type_is_comparable":
		return .Type_Comparable
	case "type_is_ordered":
		return .Type_Ordered
	case "type_is_ordered_numeric":
		return .Type_Ordered_Numeric
	case "type_is_simple_compare":
		return .Type_Simple_Compare
	case "type_is_enumerated_array":
		return .Type_Enumerated_Array
	case "type_base_type":
		return .Type_Base_Type
	case "type_core_type":
		return .Type_Core_Type
	case "sqrt":
		return .Sqrt
	case "ptr_offset":
		return .Ptr_Offset
	case "ptr_sub":
		return .Ptr_Sub
	case "__entry_point":
		return .Entry_Point
	case "read_cycle_counter":
		return .Read_Cycle_Counter
	case "x86_cpuid":
		return .X86_Cpuid
	case "x86_xgetbv":
		return .X86_Xgetbv
	case "constant_log2":
		return .Constant_Log2
	case "saturating_add":
		return .Saturating_Add
	case "saturating_sub":
		return .Saturating_Sub
	case "syscall":
		return .Syscall
	case "mem_zero_volatile":
		return .Mem_Zero_Volatile
	case "cpu_relax":
		return .Cpu_Relax
	case "debug_trap":
		return .Debug_Trap
	case "trap":
		return .Trap
	case "count_ones":
		return .Count_Ones
	case "count_zeros":
		return .Count_Zeros
	case "count_leading_zeros":
		return .Count_Leading_Zeros
	case "count_trailing_zeros":
		return .Count_Trailing_Zeros
	case "reverse_bits":
		return .Reverse_Bits
	case "byte_swap":
		return .Byte_Swap
	case "expect":
		return .Expect
	case "has_target_feature":
		return .Has_Target_Feature
	case "address_of_return_address":
		return .Address_Of_Return_Address
	case "alloca":
		return .Alloca
	case "atomic_type_is_lock_free":
		return .Atomic_Type_Is_Lock_Free
	case "concatenate":
		return .Concatenate
	case "constant_ceil":
		return .Constant_Ceil
	case "constant_floor":
		return .Constant_Floor
	case "constant_round":
		return .Constant_Round
	case "constant_trunc":
		return .Constant_Trunc
	case "constant_utf16_cstring":
		return .Constant_Utf16_Cstring
	case "count_leading_ones":
		return .Count_Leading_Ones
	case "count_trailing_ones":
		return .Count_Trailing_Ones
	case "c_va_arg":
		return .C_Va_Arg
	case "c_va_copy":
		return .C_Va_Copy
	case "c_va_end":
		return .C_Va_End
	case "c_va_start":
		return .C_Va_Start
	case "fixed_point_div":
		return .Fixed_Point_Div
	case "fixed_point_div_sat":
		return .Fixed_Point_Div_Sat
	case "fixed_point_mul":
		return .Fixed_Point_Mul
	case "fixed_point_mul_sat":
		return .Fixed_Point_Mul_Sat
	case "frame_address":
		return .Frame_Address
	case "fused_mul_add":
		return .Fused_Mul_Add
	case "hadamard_product":
		return .Hadamard_Product
	case "is_package_imported":
		return .Is_Package_Imported
	case "likely":
		return .Likely
	case "matrix_flatten":
		return .Matrix_Flatten
	case "non_temporal_load":
		return .Non_Temporal_Load
	case "non_temporal_store":
		return .Non_Temporal_Store
	case "objc_block":
		return .Objc_Block
	case "objc_find_class":
		return .Objc_Find_Class
	case "objc_find_selector":
		return .Objc_Find_Selector
	case "objc_ivar_get":
		return .Objc_Ivar_Get
	case "objc_register_class":
		return .Objc_Register_Class
	case "objc_register_selector":
		return .Objc_Register_Selector
	case "objc_super":
		return .Objc_Super
	case "outer_product":
		return .Outer_Product
	case "prefetch_read_data":
		return .Prefetch_Read_Data
	case "prefetch_read_instruction":
		return .Prefetch_Read_Instruction
	case "prefetch_write_data":
		return .Prefetch_Write_Data
	case "prefetch_write_instruction":
		return .Prefetch_Write_Instruction
	case "procedure_of":
		return .Procedure_Of
	case "read_cycle_counter_frequency":
		return .Read_Cycle_Counter_Frequency
	case "return_address":
		return .Return_Address
	case "simd_abs":
		return .Simd_Abs
	case "simd_approx_recip":
		return .Simd_Approx_Recip
	case "simd_approx_recip_sqrt":
		return .Simd_Approx_Recip_Sqrt
	case "simd_ceil":
		return .Simd_Ceil
	case "simd_clamp":
		return .Simd_Clamp
	case "simd_deinterleave":
		return .Simd_Deinterleave
	case "simd_extract_lsbs":
		return .Simd_Extract_Lsbs
	case "simd_extract_msbs":
		return .Simd_Extract_Msbs
	case "simd_floor":
		return .Simd_Floor
	case "simd_gather":
		return .Simd_Gather
	case "simd_interleave":
		return .Simd_Interleave
	case "simd_lanes_reverse":
		return .Simd_Lanes_Reverse
	case "simd_lanes_rotate_left":
		return .Simd_Lanes_Rotate_Left
	case "simd_lanes_rotate_right":
		return .Simd_Lanes_Rotate_Right
	case "simd_masked_compress_store":
		return .Simd_Masked_Compress_Store
	case "simd_masked_expand_load":
		return .Simd_Masked_Expand_Load
	case "simd_masked_load":
		return .Simd_Masked_Load
	case "simd_masked_store":
		return .Simd_Masked_Store
	case "simd_nearest":
		return .Simd_Nearest
	case "simd_neg":
		return .Simd_Neg
	case "simd_odd_even":
		return .Simd_Odd_Even
	case "simd_pairwise_add":
		return .Simd_Pairwise_Add
	case "simd_pairwise_sub":
		return .Simd_Pairwise_Sub
	case "simd_reduce_add_bisect":
		return .Simd_Reduce_Add_Bisect
	case "simd_reduce_add_ordered":
		return .Simd_Reduce_Add_Ordered
	case "simd_reduce_add_pairs":
		return .Simd_Reduce_Add_Pairs
	case "simd_reduce_all":
		return .Simd_Reduce_All
	case "simd_reduce_and":
		return .Simd_Reduce_And
	case "simd_reduce_any":
		return .Simd_Reduce_Any
	case "simd_reduce_max":
		return .Simd_Reduce_Max
	case "simd_reduce_mul_bisect":
		return .Simd_Reduce_Mul_Bisect
	case "simd_reduce_mul_ordered":
		return .Simd_Reduce_Mul_Ordered
	case "simd_reduce_mul_pairs":
		return .Simd_Reduce_Mul_Pairs
	case "simd_reduce_xor":
		return .Simd_Reduce_Xor
	case "simd_runtime_swizzle":
		return .Simd_Runtime_Swizzle
	case "simd_saturating_add":
		return .Simd_Saturating_Add
	case "simd_saturating_sub":
		return .Simd_Saturating_Sub
	case "simd_scatter":
		return .Simd_Scatter
	case "simd_sums_of_n":
		return .Simd_Sums_Of_N
	case "simd_to_bits":
		return .Simd_To_Bits
	case "simd_to_bits_signed":
		return .Simd_To_Bits_Signed
	case "simd_trunc":
		return .Simd_Trunc
	case "soa_copy_from_slice":
		return .Soa_Copy_From_Slice
	case "soa_struct":
		return .Soa_Struct
	case "stack_pointer":
		return .Stack_Pointer
	case "syscall_bsd":
		return .Syscall_Bsd
	case "transpose":
		return .Transpose
	case "type_bit_set_elem_type":
		return .Type_Bit_Set_Elem_Type
	case "type_canonical_name":
		return .Type_Canonical_Name
	case "type_convert_variants_to_pointers":
		return .Type_Convert_Variants_To_Pointers
	case "type_enum_is_contiguous":
		return .Type_Enum_Is_Contiguous
	case "type_equal_proc":
		return .Type_Equal_Proc
	case "type_field_bit_offset":
		return .Type_Field_Bit_Offset
	case "type_field_bit_size":
		return .Type_Field_Bit_Size
	case "type_field_index_of":
		return .Type_Field_Index_Of
	case "type_fixed_capacity_dynamic_array_len_offset":
		return .Type_Fixed_Capacity_Dynamic_Array_Len_Offset
	case "type_hasher_proc":
		return .Type_Hasher_Proc
	case "type_has_nil":
		return .Type_Has_Nil
	case "type_has_shared_fields":
		return .Type_Has_Shared_Fields
	case "type_integer_to_signed":
		return .Type_Integer_To_Signed
	case "type_integer_to_unsigned":
		return .Type_Integer_To_Unsigned
	case "type_is_any":
		return .Type_Is_Any
	case "type_is_bit_field":
		return .Type_Is_Bit_Field
	case "type_is_complex":
		return .Type_Is_Complex
	case "type_is_cstring":
		return .Type_Is_Cstring
	case "type_is_cstring16":
		return .Type_Is_Cstring16
	case "type_is_dereferenceable":
		return .Type_Is_Dereferenceable
	case "type_is_endian_big":
		return .Type_Is_Endian_Big
	case "type_is_endian_little":
		return .Type_Is_Endian_Little
	case "type_is_endian_platform":
		return .Type_Is_Endian_Platform
	case "type_is_fixed_capacity_dynamic_array":
		return .Type_Is_Fixed_Capacity_Dynamic_Array
	case "type_is_indexable":
		return .Type_Is_Indexable
	case "type_is_matrix":
		return .Type_Is_Matrix
	case "type_is_matrix_column_major":
		return .Type_Is_Matrix_Column_Major
	case "type_is_matrix_row_major":
		return .Type_Is_Matrix_Row_Major
	case "type_is_named":
		return .Type_Is_Named
	case "type_is_nearly_simple_compare":
		return .Type_Is_Nearly_Simple_Compare
	case "type_is_quaternion":
		return .Type_Is_Quaternion
	case "type_is_rune":
		return .Type_Is_Rune
	case "type_is_simd_vector":
		return .Type_Is_Simd_Vector
	case "type_is_sliceable":
		return .Type_Is_Sliceable
	case "type_is_specialization_of":
		return .Type_Is_Specialization_Of
	case "type_is_specialized_polymorphic_record":
		return .Type_Is_Specialized_Polymorphic_Record
	case "type_is_string":
		return .Type_Is_String
	case "type_is_string16":
		return .Type_Is_String16
	case "type_is_subtype_of":
		return .Type_Is_Subtype_Of
	case "type_is_superset_of":
		return .Type_Is_Superset_Of
	case "type_is_typeid":
		return .Type_Is_Typeid
	case "type_is_unspecialized_polymorphic_record":
		return .Type_Is_Unspecialized_Polymorphic_Record
	case "type_is_valid_map_key":
		return .Type_Is_Valid_Map_Key
	case "type_is_valid_matrix_elements":
		return .Type_Is_Valid_Matrix_Elements
	case "type_is_variant_of":
		return .Type_Is_Variant_Of
	case "type_merge":
		return .Type_Merge
	case "type_polymorphic_record_parameter_count":
		return .Type_Polymorphic_Record_Parameter_Count
	case "type_polymorphic_record_parameter_value":
		return .Type_Polymorphic_Record_Parameter_Value
	case "type_proc_calling_convention":
		return .Type_Proc_Calling_Convention
	case "type_proc_parameter_count":
		return .Type_Proc_Parameter_Count
	case "type_proc_parameter_type":
		return .Type_Proc_Parameter_Type
	case "type_proc_return_count":
		return .Type_Proc_Return_Count
	case "type_proc_return_type":
		return .Type_Proc_Return_Type
	case "type_struct_has_implicit_padding":
		return .Type_Struct_Has_Implicit_Padding
	case "type_union_base_tag_value":
		return .Type_Union_Base_Tag_Value
	case "type_union_tag_offset":
		return .Type_Union_Tag_Offset
	case "type_union_tag_type":
		return .Type_Union_Tag_Type
	case "type_union_variant_count":
		return .Type_Union_Variant_Count
	case "type_variant_index_of":
		return .Type_Variant_Index_Of
	case "type_variant_type_of":
		return .Type_Variant_Type_Of
	case "unlikely":
		return .Unlikely
	case "valgrind_client_request":
		return .Valgrind_Client_Request
	case "wasm_memory_atomic_notify32":
		return .Wasm_Memory_Atomic_Notify32
	case "wasm_memory_atomic_wait32":
		return .Wasm_Memory_Atomic_Wait32
	case "wasm_memory_grow":
		return .Wasm_Memory_Grow
	case "wasm_memory_size":
		return .Wasm_Memory_Size
	case "volatile_load":
		return .Volatile_Load
	case "volatile_store":
		return .Volatile_Store
	case "atomic_load":
		return .Atomic_Load
	case "atomic_store":
		return .Atomic_Store
	case "atomic_add":
		return .Atomic_Add
	case "atomic_sub":
		return .Atomic_Sub
	case "atomic_and":
		return .Atomic_And
	case "atomic_nand":
		return .Atomic_Nand
	case "atomic_or":
		return .Atomic_Or
	case "atomic_xor":
		return .Atomic_Xor
	case "atomic_exchange":
		return .Atomic_Exchange
	case "atomic_compare_exchange_strong":
		return .Atomic_Compare_Exchange_Strong
	case "atomic_compare_exchange_weak":
		return .Atomic_Compare_Exchange_Weak
	case "atomic_load_explicit":
		return .Atomic_Load_Explicit
	case "atomic_store_explicit":
		return .Atomic_Store_Explicit
	case "atomic_add_explicit":
		return .Atomic_Add_Explicit
	case "atomic_sub_explicit":
		return .Atomic_Sub_Explicit
	case "atomic_and_explicit":
		return .Atomic_And_Explicit
	case "atomic_nand_explicit":
		return .Atomic_Nand_Explicit
	case "atomic_or_explicit":
		return .Atomic_Or_Explicit
	case "atomic_xor_explicit":
		return .Atomic_Xor_Explicit
	case "atomic_exchange_explicit":
		return .Atomic_Exchange_Explicit
	case "atomic_compare_exchange_strong_explicit":
		return .Atomic_Compare_Exchange_Strong_Explicit
	case "atomic_compare_exchange_weak_explicit":
		return .Atomic_Compare_Exchange_Weak_Explicit
	case "atomic_thread_fence":
		return .Atomic_Thread_Fence
	case "atomic_signal_fence":
		return .Atomic_Signal_Fence
	case "overflow_add":
		return .Overflow_Add
	case "overflow_sub":
		return .Overflow_Sub
	case "overflow_mul":
		return .Overflow_Mul
	case "mem_copy":
		return .Mem_Copy
	case "mem_copy_non_overlapping":
		return .Mem_Copy_Non_Overlapping
	case "mem_zero":
		return .Mem_Zero
	case "unaligned_load":
		return .Unaligned_Load
	case "unaligned_store":
		return .Unaligned_Store
	case "simd_extract":
		return .Simd_Extract
	case "simd_replace":
		return .Simd_Replace
	case "simd_indices":
		return .Simd_Indices
	case "simd_select":
		return .Simd_Select
	case "simd_shuffle":
		return .Simd_Shuffle
	case "simd_lanes_ne":
		return .Simd_Lanes_Ne
	case "simd_lanes_eq":
		return .Simd_Lanes_Eq
	case "simd_lanes_lt":
		return .Simd_Lanes_Lt
	case "simd_lanes_le":
		return .Simd_Lanes_Le
	case "simd_lanes_gt":
		return .Simd_Lanes_Gt
	case "simd_lanes_ge":
		return .Simd_Lanes_Ge
	case "simd_add":
		return .Simd_Add
	case "simd_sub":
		return .Simd_Sub
	case "simd_mul":
		return .Simd_Mul
	case "simd_div":
		return .Simd_Div
	case "simd_bit_and":
		return .Simd_Bit_And
	case "simd_bit_or":
		return .Simd_Bit_Or
	case "simd_bit_xor":
		return .Simd_Bit_Xor
	case "simd_bit_and_not":
		return .Simd_Bit_And_Not
	case "simd_min":
		return .Simd_Min
	case "simd_max":
		return .Simd_Max
	case "simd_shl":
		return .Simd_Shl
	case "simd_shr":
		return .Simd_Shr
	case "simd_shl_masked":
		return .Simd_Shl_Masked
	case "simd_shr_masked":
		return .Simd_Shr_Masked
	case "simd_reduce_or":
		return .Simd_Reduce_Or
	case "simd_reduce_min":
		return .Simd_Reduce_Min
	}
	return .None
}

@(private = "package")
expression_builtin_id :: proc(checker: ^Expression_Checker, kind: Builtin_Kind) -> (id: Builtin_Id, err: runtime.Allocator_Error) {
	if len(checker.builtin_kinds) == 0 { append(&checker.builtin_kinds, Builtin_Kind.None) or_return }
	append(&checker.builtin_kinds, kind) or_return
	return Builtin_Id(len(checker.builtin_kinds) - 1), nil
}

@(private = "package")
expression_in_intrinsics :: proc(checker: ^Expression_Checker, package_id: Package_Id) -> bool {
	return int(package_id) < len(checker.packages) && checker.packages[package_id].kind == .Intrinsics
}

// A bodiless procedure of base:intrinsics becomes a builtin entity. Unlisted names remain unsupported.
@(private = "package")
expression_intrinsic_declaration :: proc(
	checker: ^Expression_Checker,
	resolver: ^Resolver,
	id: Entity_Id,
	view: View_Id,
	node: syntax.Node_Index,
) -> (
	valid: bool,
	err: Resolve_Error,
) {
	kind := intrinsic_builtin_kind(entity_get(resolver.scopes, id).name)
	if kind == .None {
		expression_unsupported(checker, view, entity_get(resolver.scopes, id).scope, node, "Builtin_Declaration") or_return
		return false, nil
	}
	builtin := expression_builtin_id(checker, kind) or_return
	binding := entity_get(resolver.scopes, id)
	binding.kind = .Builtin
	binding.data = builtin
	return true, nil
}

// A syscall takes its number and up to six words; every argument is converted to uintptr by its own row.
@(private = "package")
expression_builtin_call :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	callee: Expression_Info,
	arguments: []syntax.Node_Index,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if callee.state == .Invalid { return expression_poison(scope), nil }
	file := checker.type_checker.files[file_id]
	call := syntax.node_payload(file.ast, node, syntax.Call_Expr)
	builtin := entity_get(checker.type_checker.resolver.scopes, callee.entity).data.(Builtin_Id)
	if kind := checker.builtin_kinds[builtin]; kind >= .Type_Array && kind <= .Type_Elem_Type {
		return expression_type_query(checker, view, scope, node, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind >= .Type_Comparable && kind <= .Type_Core_Type {
		return expression_type_predicate(checker, view, scope, node, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind == .Saturating_Add || kind == .Saturating_Sub {
		return expression_saturating(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if checker.builtin_kinds[builtin] == .Constant_Log2 {
		return expression_constant_log2(checker, view, scope, node, arguments, call.ellipsis.kind != .Invalid)
	}
	if checker.builtin_kinds[builtin] == .Type_Info_Of {
		return expression_type_info_of(checker, view, scope, node, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind == .Type_Map_Info || kind == .Type_Map_Cell_Info {
		return expression_map_info(checker, view, scope, node, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind == .Min || kind == .Max || kind == .Abs || kind == .Clamp {
		return expression_numeric_builtin(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if checker.builtin_kinds[builtin] == .Entry_Point {
		if len(arguments) != 0 || call.ellipsis.kind != .Invalid { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Builtin_Plan{builtin = builtin})) or_return
		return Expression_Info{mode = .No_Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	if checker.builtin_kinds[builtin] == .Trap {
		if len(arguments) != 0 || call.ellipsis.kind != .Invalid { return expression_unsupported(checker, view, scope, node, "Trap_Arguments") }
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Builtin_Plan{builtin = builtin})) or_return
		return Expression_Info{mode = .No_Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	if checker.builtin_kinds[builtin] == .Unreachable {
		if len(arguments) != 0 || call.ellipsis.kind != .Invalid { return expression_unsupported(checker, view, scope, node, "Unreachable_Arguments") }
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Builtin_Plan{builtin = builtin})) or_return
		return Expression_Info{mode = .No_Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	if kind := checker.builtin_kinds[builtin]; kind == .Size_Of || kind == .Align_Of {
		return expression_layout_query(checker, view, scope, node, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind == .Offset_Of || kind == .Offset_Of_By_String {
		return expression_offset_of(checker, view, file_id, scope, node, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if checker.builtin_kinds[builtin] == .Typeid_Of {
		return expression_typeid_of(checker, view, scope, node, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind >= .Complex && kind <= .Conj {
		return expression_complex_builtin(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid, hint)
	}
	if kind := checker.builtin_kinds[builtin]; kind == .Hadamard_Product || kind == .Outer_Product || kind == .Matrix_Flatten {
		return expression_matrix_builtin(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid, hint)
	}
	if checker.builtin_kinds[builtin] == .Has_Target_Feature {
		return expression_has_target_feature(checker, view, scope, node, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind == .Len || kind == .Cap {
		return expression_length(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid, hint)
	}
	if checker.builtin_kinds[builtin] == .Raw_Data {
		return expression_raw_data(checker, view, scope, node, builtin, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; simd_builtin_kind(kind) {
		return expression_simd_call(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; target_op_kind(kind) {
		return expression_target_op(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; intrinsic_shape(kind) != .None {
		return expression_intrinsic_call(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if simd_reduction_kind(checker.builtin_kinds[builtin]) {
		return expression_simd_reduction(checker, view, scope, node, builtin, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind >= .C_Va_Arg && kind <= .C_Va_Start {
		return expression_c_varargs(checker, view, scope, node, builtin, arguments, call.ellipsis.kind != .Invalid)
	}
	if checker.builtin_kinds[builtin] != .Syscall {
		return expression_unsupported(checker, view, scope, node, entity_get(checker.type_checker.resolver.scopes, callee.entity).name)
	}
	if call.ellipsis.kind != .Invalid || len(arguments) < 1 || len(arguments) > 7 {
		return expression_unsupported(checker, view, scope, node, "Syscall_Arguments")
	}
	word := checker.config.uintptr
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, len(arguments), allocator) or_return
	for argument, index in arguments {
		value := check_expression(checker, view, scope, argument, word) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		operands[index] = Operand(Expression_Ref{view, argument})
	}
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = word, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "file")
expression_raw_data :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_unsupported(checker, view, scope, node, "Raw_Data_Arguments") }
	operand := check_expression(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	#partial switch operand.mode {
	case .Value,
	     .Immutable_Value,
	     .Variable,
	     .Constant,
	     .Context,
	     .Map_Index,
	     .Optional_Ok,
	     .Optional_Ok_Pointer,
	     .Soa_Variable,
	     .Swizzle_Value,
	     .Swizzle_Variable:
	case:
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand)
	}
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, operand.type))
	element: types.Type_Id
	#partial switch descriptor.kind {
	case .Slice, .Dynamic_Array:
		element = descriptor.elem
	case .String:
		element = types.sized_integer(store, 1, false)
	case .String16:
		element = types.sized_integer(store, 2, false)
	case .Pointer, .Multi_Pointer:
		// Official raw_data also takes pointers to arrays, returning a multi-pointer to the element.
		pointed := types.get(store, types.resolve_named(store, descriptor.elem))^
		#partial switch pointed.kind {
		case .Array, .Enumerated_Array, .Simd_Vector:
			element = pointed.elem
		case:
			return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand)
		}
	case:
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand)
	}
	result := types.intern(store, types.Type{kind = .Multi_Pointer, elem = element})
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, 1, allocator) or_return
	operands[0] = Operand(Expression_Ref{view, arguments[0]})
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "file")
expression_constant_log2 :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_unsupported(checker, view, scope, node, "Constant_Log2_Arguments") }
	operand := check_expression(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	value := constant_pool_get(checker.constants, operand.constant)
	if operand.mode != .Constant ||
	   value == nil ||
	   !conversion_integer(types.get(checker.type_checker.store, conversion_base_type(checker.type_checker.store, operand.type)).kind) {
		return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand)
	}
	integer, is_integer := value.value.(big.Int)
	if !is_integer { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	count, count_error := big.count_bits(&integer)
	if count_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, count_error) or_return
		return expression_poison(scope), nil
	}
	result: big.Int
	defer big.destroy(&result)
	if failure := big.set(&result, count - 1); failure != nil {
		expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
		return expression_poison(scope), nil
	}
	constant, failure := constant_pool_intern_integer(checker.constants, &result, types.TYPE_UNTYPED_INTEGER)
	if failure != nil {
		expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = types.TYPE_UNTYPED_INTEGER, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

@(private = "file")
expression_numeric_builtin :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	count := len(arguments)
	if (kind == .Min || kind == .Max) && count == 1 && !ellipsis {
		return expression_extremum_of_type(checker, view, scope, node, kind, arguments[0])
	}
	if ellipsis || (kind == .Abs && count != 1) || (kind == .Clamp && count != 3) || ((kind == .Min || kind == .Max) && count < 2) {
		return expression_unsupported(checker, view, scope, node, "Numeric_Arguments")
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	values := make([]Expression_Info, count, allocator) or_return
	result_type: types.Type_Id
	constant := true
	for argument, index in arguments {
		value := check_expression(checker, view, scope, argument) or_return
		if value.state == .Invalid { return expression_poison(scope), nil }
		descriptor := types.get(store, types.resolve_named(store, value.type))
		if value.mode == .Type || !(conversion_integer(descriptor.kind) || conversion_float(descriptor.kind)) {
			return expression_failure(checker, view, scope, argument, .Invalid_Operand)
		}
		values[index] = value
		constant &&= value.mode == .Constant
		if result_type == 0 ||
		   conversion_untyped(types.get(store, result_type).kind) && (!conversion_untyped(descriptor.kind) || descriptor.kind == .Untyped_Float) {
			result_type = value.type
		}
	}
	for argument, index in arguments {
		values[index] = check_expression(checker, view, scope, argument, result_type) or_return
		if values[index].state == .Invalid { return expression_poison(scope), nil }
	}
	if constant {
		result, failure := constant_numeric_builtin(checker.constants, store, kind, values, result_type)
		if failure != nil {
			expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = result_type, constant = result, mode = .Constant, scope = scope, state = .Checked}, nil
	}
	operands := make([]Operand, count, allocator) or_return
	for argument, index in arguments { operands[index] = Operand(Expression_Ref{view, argument}) }
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = result_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "file")
constant_numeric_builtin :: proc(
	pool: ^Constant_Pool,
	store: ^types.Store,
	kind: Builtin_Kind,
	values: []Expression_Info,
	result_type: types.Type_Id,
) -> (
	result: Const_Id,
	err: Constant_Error,
) {
	result = values[0].constant
	if kind == .Abs {
		constant := constant_pool_get(pool, result)^
		#partial switch &value in constant.value {
		case big.Int:
			absolute: big.Int
			defer big.destroy(&absolute)
			big.abs(&absolute, &value) or_return
			constant := constant_pool_intern_integer(pool, &absolute, result_type) or_return
			return constant_unary_operator(pool, .Add, constant, result_type, store)
		case big.Rat:
			absolute: big.Rat
			defer big.destroy(&absolute)
			big.abs(&absolute, &value) or_return
			return constant_pool_intern_rational(pool, &absolute, result_type)
		case Float_Value:
			value.bits &= ~(u64(1) << (value.width - 1))
			return constant_pool_intern_float(pool, value, result_type)
		}
		return 0, Constant_Pool_Error.Invalid_Operand
	}
	if kind == .Clamp {
		below := constant_compare_operator(pool, .Lt, result, values[1].constant) or_return
		if constant_pool_get(pool, below).value.(bool) { return values[1].constant, nil }
		above := constant_compare_operator(pool, .Gt, result, values[2].constant) or_return
		if constant_pool_get(pool, above).value.(bool) { return values[2].constant, nil }
		return result, nil
	}
	for value in values[1:] {
		want_min := kind == .Min
		comparison := constant_compare_operator(pool, .Lt, result, value.constant) or_return
		less := constant_pool_get(pool, comparison).value.(bool)
		if less != want_min { result = value.constant }
	}
	return result, nil
}

// min(T) and max(T) preserve the queried type.
@(private = "file")
expression_extremum_of_type :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	kind: Builtin_Kind,
	argument: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	operand := check_expression(checker, view, scope, argument) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, operand.type))
	if operand.mode != .Type { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	if descriptor.kind == .Enum {
		members := checker.type_checker.enum_members[types.resolve_named(store, operand.type)]
		if len(members) == 0 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		extreme := members[0]
		for member in members[1:] {
			if kind == .Min && member.value < extreme.value || kind == .Max && member.value > extreme.value { extreme = member }
		}
		return expression_enum_member(checker, view, scope, node, operand.type, extreme.name)
	}
	if !conversion_integer(descriptor.kind) { return expression_unsupported(checker, view, scope, node, "Extremum_Type") }
	size, _, layout_error := types.layout(store, operand.type)
	if layout_error != .None { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	bits := int(size) * 8
	value: big.Int
	defer big.destroy(&value)
	failure: big.Error
	if kind == .Min && !descriptor.signed {
		failure = big.set(&value, 0)
	} else {
		magnitude_bits := bits
		if descriptor.signed { magnitude_bits -= 1 }
		failure = big.power_of_two(&value, magnitude_bits)
		if failure == nil && kind == .Max { failure = big.int_sub_digit(&value, &value, 1) }
		if failure == nil && kind == .Min { failure = big.int_neg(&value, &value) }
	}
	if failure != nil {
		expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
		return expression_poison(scope), nil
	}
	constant, constant_error := constant_pool_intern_integer(checker.constants, &value, operand.type)
	if constant_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = operand.type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

// size_of and align_of fold to the target layout of the operand's type, as an untyped integer does in the official compiler.
@(private = "file")
expression_layout_query :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_unsupported(checker, view, scope, node, "Layout_Query_Arguments") }
	operand := check_expression(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	size, alignment, layout_error := types.layout(checker.type_checker.store, operand.type)
	if layout_error != .None { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	bytes := size
	if kind == .Align_Of { bytes = alignment }
	value: big.Int
	defer big.destroy(&value)
	if set_error := big.set(&value, bytes); set_error != nil {
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

// has_target_feature folds to an untyped bool: every comma-separated feature must be in the build's target features.
@(private = "file")
expression_has_target_feature :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_unsupported(checker, view, scope, node, "Target_Feature_Arguments") }
	feature := check_expression(checker, view, scope, arguments[0]) or_return
	if feature.state == .Invalid { return expression_poison(scope), nil }
	names, is_string := constant_pool_get(checker.constants, feature.constant).value.(string)
	if feature.mode != .Constant || !is_string { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	enabled := true
	for name in strings.split_iterator(&names, ",") {
		enabled &&= target_feature_enabled(checker.target_features, name)
	}
	constant, constant_error := constant_pool_intern_bool(checker.constants, enabled, types.TYPE_UNTYPED_BOOL)
	if constant_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = types.TYPE_UNTYPED_BOOL, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

@(private = "file")
target_feature_enabled :: proc(features: []string, name: string) -> bool {
	for feature in features {
		if feature == name { return true }
	}
	return false
}

// len and cap of a fixed array, and len of a constant string, are constants. len of a slice or runtime string is read from its header during lowering.
@(private = "file")
expression_length :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 1 || ellipsis { return expression_unsupported(checker, view, scope, node, "Length_Arguments") }
	operand := check_expression(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, operand.type))
	if descriptor.kind == .Pointer {
		descriptor = types.get(store, types.resolve_named(store, descriptor.elem))
	}
	#partial switch descriptor.kind {
	case .Array, .Enumerated_Array, .Enum:
		if descriptor.kind == .Enum && operand.mode != .Type || descriptor.kind != .Array && kind == .Cap {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
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
	case .Slice, .Dynamic_Array, .Map, .String, .String16, .CString, .CString16:
		if kind == .Len && operand.mode == .Constant && operand.constant != 0 {
			length, known := constant_string_length(checker, operand.constant)
			if known {
				value: big.Int
				defer big.destroy(&value)
				if set_error := big.set(&value, i64(length)); set_error != nil {
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
		}
		if kind == .Cap && descriptor.kind != .Dynamic_Array && descriptor.kind != .Map {
			return expression_failure(checker, view, scope, node, .Invalid_Operand)
		}
		if operand.mode == .Type { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		allocator := mem.dynamic_arena_allocator(&checker.arena)
		operands := make([]Operand, 1, allocator) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
		result := checker.default_integer
		if hinted := length_integer_hint(checker, hint); hinted != 0 { result = hinted }
		return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	return expression_failure(checker, view, scope, node, .Invalid_Operand)
}

// Runtime len and cap follow an int or uint hint. Any other hint stays int.
@(private = "package")
length_integer_hint :: proc(checker: ^Expression_Checker, hint: types.Type_Id) -> types.Type_Id {
	if hint == 0 { return 0 }
	name := types.get(checker.type_checker.store, hint).name
	if name == "int" || name == "uint" { return hint }
	return 0
}

@(private = "file")
constant_string_length :: proc(checker: ^Expression_Checker, id: Const_Id) -> (length: int, known: bool) {
	constant := constant_pool_get(checker.constants, id)
	if constant == nil { return 0, false }
	#partial switch text in constant.value {
	case string:
		return len(text), true
	case []u16:
		return len(text), true
	}
	return 0, false
}

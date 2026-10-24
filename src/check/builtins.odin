package check

import "base:runtime"
import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

Intrinsic_Binding :: struct {
	name: string,
	kind: Builtin_Kind,
}

intrinsic_bindings :: proc() -> [280]Intrinsic_Binding {
	bindings :: [?]Intrinsic_Binding {
		{"type_is_array", .Type_Array},
		{"type_is_pointer", .Type_Pointer},
		{"type_is_struct", .Type_Struct},
		{"type_is_slice", .Type_Slice},
		{"type_is_integer", .Type_Integer},
		{"type_is_float", .Type_Float},
		{"type_is_numeric", .Type_Numeric},
		{"type_is_unsigned", .Type_Unsigned},
		{"type_is_proc", .Type_Proc},
		{"type_is_internally_pointer_like", .Type_Internally_Pointer_Like},
		{"type_is_boolean", .Type_Boolean},
		{"type_is_multi_pointer", .Type_Multi_Pointer},
		{"type_is_dynamic_array", .Type_Dynamic_Array},
		{"type_is_map", .Type_Map},
		{"type_is_union", .Type_Union},
		{"type_is_enum", .Type_Enum},
		{"type_is_bit_set", .Type_Bit_Set},
		{"type_struct_field_count", .Type_Struct_Field_Count},
		{"type_has_field", .Type_Has_Field},
		{"type_field_type", .Type_Field_Type},
		{"type_bit_set_underlying_type", .Type_Bit_Set_Underlying_Type},
		{"type_elem_type", .Type_Elem_Type},
		{"type_map_info", .Type_Map_Info},
		{"type_map_cell_info", .Type_Map_Cell_Info},
		{"type_is_comparable", .Type_Comparable},
		{"type_is_ordered", .Type_Ordered},
		{"type_is_ordered_numeric", .Type_Ordered_Numeric},
		{"type_is_simple_compare", .Type_Simple_Compare},
		{"type_is_enumerated_array", .Type_Enumerated_Array},
		{"type_base_type", .Type_Base_Type},
		{"type_core_type", .Type_Core_Type},
		{"sqrt", .Sqrt},
		{"ptr_offset", .Ptr_Offset},
		{"ptr_sub", .Ptr_Sub},
		{"__entry_point", .Entry_Point},
		{"read_cycle_counter", .Read_Cycle_Counter},
		{"x86_cpuid", .X86_Cpuid},
		{"x86_xgetbv", .X86_Xgetbv},
		{"x86_aesenc", .X86_Aesenc},
		{"x86_aesenclast", .X86_Aesenclast},
		{"x86_aesimc", .X86_Aesimc},
		{"x86_aeskeygenassist", .X86_Aeskeygenassist},
		{"x86_aesdec", .X86_Aesdec},
		{"x86_aesdeclast", .X86_Aesdeclast},
		{"x86_pclmulqdq", .X86_Pclmulqdq},
		{"x86_sha256msg1", .X86_Sha256msg1},
		{"x86_sha256msg2", .X86_Sha256msg2},
		{"x86_sha256rnds2", .X86_Sha256rnds2},
		{"constant_log2", .Constant_Log2},
		{"saturating_add", .Saturating_Add},
		{"saturating_sub", .Saturating_Sub},
		{"syscall", .Syscall},
		{"mem_zero_volatile", .Mem_Zero_Volatile},
		{"cpu_relax", .Cpu_Relax},
		{"debug_trap", .Debug_Trap},
		{"trap", .Trap},
		{"count_ones", .Count_Ones},
		{"count_zeros", .Count_Zeros},
		{"count_leading_zeros", .Count_Leading_Zeros},
		{"count_trailing_zeros", .Count_Trailing_Zeros},
		{"reverse_bits", .Reverse_Bits},
		{"byte_swap", .Byte_Swap},
		{"expect", .Expect},
		{"has_target_feature", .Has_Target_Feature},
		{"address_of_return_address", .Address_Of_Return_Address},
		{"alloca", .Alloca},
		{"atomic_type_is_lock_free", .Atomic_Type_Is_Lock_Free},
		{"concatenate", .Concatenate},
		{"constant_ceil", .Constant_Ceil},
		{"constant_floor", .Constant_Floor},
		{"constant_round", .Constant_Round},
		{"constant_trunc", .Constant_Trunc},
		{"constant_utf16_cstring", .Constant_Utf16_Cstring},
		{"count_leading_ones", .Count_Leading_Ones},
		{"count_trailing_ones", .Count_Trailing_Ones},
		{"c_va_arg", .C_Va_Arg},
		{"c_va_copy", .C_Va_Copy},
		{"c_va_end", .C_Va_End},
		{"c_va_start", .C_Va_Start},
		{"fixed_point_div", .Fixed_Point_Div},
		{"fixed_point_div_sat", .Fixed_Point_Div_Sat},
		{"fixed_point_mul", .Fixed_Point_Mul},
		{"fixed_point_mul_sat", .Fixed_Point_Mul_Sat},
		{"frame_address", .Frame_Address},
		{"fused_mul_add", .Fused_Mul_Add},
		{"hadamard_product", .Hadamard_Product},
		{"is_package_imported", .Is_Package_Imported},
		{"likely", .Likely},
		{"matrix_flatten", .Matrix_Flatten},
		{"non_temporal_load", .Non_Temporal_Load},
		{"non_temporal_store", .Non_Temporal_Store},
		{"objc_block", .Objc_Block},
		{"objc_find_class", .Objc_Find_Class},
		{"objc_find_selector", .Objc_Find_Selector},
		{"objc_ivar_get", .Objc_Ivar_Get},
		{"objc_register_class", .Objc_Register_Class},
		{"objc_register_selector", .Objc_Register_Selector},
		{"objc_super", .Objc_Super},
		{"outer_product", .Outer_Product},
		{"prefetch_read_data", .Prefetch_Read_Data},
		{"prefetch_read_instruction", .Prefetch_Read_Instruction},
		{"prefetch_write_data", .Prefetch_Write_Data},
		{"prefetch_write_instruction", .Prefetch_Write_Instruction},
		{"procedure_of", .Procedure_Of},
		{"read_cycle_counter_frequency", .Read_Cycle_Counter_Frequency},
		{"return_address", .Return_Address},
		{"simd_abs", .Simd_Abs},
		{"simd_approx_recip", .Simd_Approx_Recip},
		{"simd_approx_recip_sqrt", .Simd_Approx_Recip_Sqrt},
		{"simd_ceil", .Simd_Ceil},
		{"simd_clamp", .Simd_Clamp},
		{"simd_deinterleave", .Simd_Deinterleave},
		{"simd_extract_lsbs", .Simd_Extract_Lsbs},
		{"simd_extract_msbs", .Simd_Extract_Msbs},
		{"simd_floor", .Simd_Floor},
		{"simd_gather", .Simd_Gather},
		{"simd_interleave", .Simd_Interleave},
		{"simd_lanes_reverse", .Simd_Lanes_Reverse},
		{"simd_lanes_rotate_left", .Simd_Lanes_Rotate_Left},
		{"simd_lanes_rotate_right", .Simd_Lanes_Rotate_Right},
		{"simd_masked_compress_store", .Simd_Masked_Compress_Store},
		{"simd_masked_expand_load", .Simd_Masked_Expand_Load},
		{"simd_masked_load", .Simd_Masked_Load},
		{"simd_masked_store", .Simd_Masked_Store},
		{"simd_nearest", .Simd_Nearest},
		{"simd_neg", .Simd_Neg},
		{"simd_odd_even", .Simd_Odd_Even},
		{"simd_pairwise_add", .Simd_Pairwise_Add},
		{"simd_pairwise_sub", .Simd_Pairwise_Sub},
		{"simd_reduce_add_bisect", .Simd_Reduce_Add_Bisect},
		{"simd_reduce_add_ordered", .Simd_Reduce_Add_Ordered},
		{"simd_reduce_add_pairs", .Simd_Reduce_Add_Pairs},
		{"simd_reduce_all", .Simd_Reduce_All},
		{"simd_reduce_and", .Simd_Reduce_And},
		{"simd_reduce_any", .Simd_Reduce_Any},
		{"simd_reduce_max", .Simd_Reduce_Max},
		{"simd_reduce_mul_bisect", .Simd_Reduce_Mul_Bisect},
		{"simd_reduce_mul_ordered", .Simd_Reduce_Mul_Ordered},
		{"simd_reduce_mul_pairs", .Simd_Reduce_Mul_Pairs},
		{"simd_reduce_xor", .Simd_Reduce_Xor},
		{"simd_runtime_swizzle", .Simd_Runtime_Swizzle},
		{"simd_saturating_add", .Simd_Saturating_Add},
		{"simd_saturating_sub", .Simd_Saturating_Sub},
		{"simd_scatter", .Simd_Scatter},
		{"simd_sums_of_n", .Simd_Sums_Of_N},
		{"simd_to_bits", .Simd_To_Bits},
		{"simd_to_bits_signed", .Simd_To_Bits_Signed},
		{"simd_trunc", .Simd_Trunc},
		{"soa_copy_from_slice", .Soa_Copy_From_Slice},
		{"soa_struct", .Soa_Struct},
		{"stack_pointer", .Stack_Pointer},
		{"syscall_bsd", .Syscall_Bsd},
		{"transpose", .Transpose},
		{"type_bit_set_elem_type", .Type_Bit_Set_Elem_Type},
		{"type_canonical_name", .Type_Canonical_Name},
		{"type_convert_variants_to_pointers", .Type_Convert_Variants_To_Pointers},
		{"type_enum_is_contiguous", .Type_Enum_Is_Contiguous},
		{"type_equal_proc", .Type_Equal_Proc},
		{"type_field_bit_offset", .Type_Field_Bit_Offset},
		{"type_field_bit_size", .Type_Field_Bit_Size},
		{"type_field_index_of", .Type_Field_Index_Of},
		{"type_fixed_capacity_dynamic_array_len_offset", .Type_Fixed_Capacity_Dynamic_Array_Len_Offset},
		{"type_hasher_proc", .Type_Hasher_Proc},
		{"type_has_nil", .Type_Has_Nil},
		{"type_has_shared_fields", .Type_Has_Shared_Fields},
		{"type_integer_to_signed", .Type_Integer_To_Signed},
		{"type_integer_to_unsigned", .Type_Integer_To_Unsigned},
		{"type_is_any", .Type_Is_Any},
		{"type_is_bit_field", .Type_Is_Bit_Field},
		{"type_is_complex", .Type_Is_Complex},
		{"type_is_cstring", .Type_Is_Cstring},
		{"type_is_cstring16", .Type_Is_Cstring16},
		{"type_is_dereferenceable", .Type_Is_Dereferenceable},
		{"type_is_endian_big", .Type_Is_Endian_Big},
		{"type_is_endian_little", .Type_Is_Endian_Little},
		{"type_is_endian_platform", .Type_Is_Endian_Platform},
		{"type_is_fixed_capacity_dynamic_array", .Type_Is_Fixed_Capacity_Dynamic_Array},
		{"type_is_indexable", .Type_Is_Indexable},
		{"type_is_matrix", .Type_Is_Matrix},
		{"type_is_matrix_column_major", .Type_Is_Matrix_Column_Major},
		{"type_is_matrix_row_major", .Type_Is_Matrix_Row_Major},
		{"type_is_named", .Type_Is_Named},
		{"type_is_nearly_simple_compare", .Type_Is_Nearly_Simple_Compare},
		{"type_is_quaternion", .Type_Is_Quaternion},
		{"type_is_rune", .Type_Is_Rune},
		{"type_is_simd_vector", .Type_Is_Simd_Vector},
		{"type_is_sliceable", .Type_Is_Sliceable},
		{"type_is_specialization_of", .Type_Is_Specialization_Of},
		{"type_is_specialized_polymorphic_record", .Type_Is_Specialized_Polymorphic_Record},
		{"type_is_string", .Type_Is_String},
		{"type_is_string16", .Type_Is_String16},
		{"type_is_subtype_of", .Type_Is_Subtype_Of},
		{"type_is_superset_of", .Type_Is_Superset_Of},
		{"type_is_typeid", .Type_Is_Typeid},
		{"type_is_unspecialized_polymorphic_record", .Type_Is_Unspecialized_Polymorphic_Record},
		{"type_is_valid_map_key", .Type_Is_Valid_Map_Key},
		{"type_is_valid_matrix_elements", .Type_Is_Valid_Matrix_Elements},
		{"type_is_variant_of", .Type_Is_Variant_Of},
		{"type_merge", .Type_Merge},
		{"type_polymorphic_record_parameter_count", .Type_Polymorphic_Record_Parameter_Count},
		{"type_polymorphic_record_parameter_value", .Type_Polymorphic_Record_Parameter_Value},
		{"type_proc_calling_convention", .Type_Proc_Calling_Convention},
		{"type_proc_parameter_count", .Type_Proc_Parameter_Count},
		{"type_proc_parameter_type", .Type_Proc_Parameter_Type},
		{"type_proc_return_count", .Type_Proc_Return_Count},
		{"type_proc_return_type", .Type_Proc_Return_Type},
		{"type_struct_has_implicit_padding", .Type_Struct_Has_Implicit_Padding},
		{"type_union_base_tag_value", .Type_Union_Base_Tag_Value},
		{"type_union_tag_offset", .Type_Union_Tag_Offset},
		{"type_union_tag_type", .Type_Union_Tag_Type},
		{"type_union_variant_count", .Type_Union_Variant_Count},
		{"type_variant_index_of", .Type_Variant_Index_Of},
		{"type_variant_type_of", .Type_Variant_Type_Of},
		{"unlikely", .Unlikely},
		{"valgrind_client_request", .Valgrind_Client_Request},
		{"wasm_memory_atomic_notify32", .Wasm_Memory_Atomic_Notify32},
		{"wasm_memory_atomic_wait32", .Wasm_Memory_Atomic_Wait32},
		{"wasm_memory_grow", .Wasm_Memory_Grow},
		{"wasm_memory_size", .Wasm_Memory_Size},
		{"volatile_load", .Volatile_Load},
		{"volatile_store", .Volatile_Store},
		{"atomic_load", .Atomic_Load},
		{"atomic_store", .Atomic_Store},
		{"atomic_add", .Atomic_Add},
		{"atomic_sub", .Atomic_Sub},
		{"atomic_and", .Atomic_And},
		{"atomic_nand", .Atomic_Nand},
		{"atomic_or", .Atomic_Or},
		{"atomic_xor", .Atomic_Xor},
		{"atomic_exchange", .Atomic_Exchange},
		{"atomic_compare_exchange_strong", .Atomic_Compare_Exchange_Strong},
		{"atomic_compare_exchange_weak", .Atomic_Compare_Exchange_Weak},
		{"atomic_load_explicit", .Atomic_Load_Explicit},
		{"atomic_store_explicit", .Atomic_Store_Explicit},
		{"atomic_add_explicit", .Atomic_Add_Explicit},
		{"atomic_sub_explicit", .Atomic_Sub_Explicit},
		{"atomic_and_explicit", .Atomic_And_Explicit},
		{"atomic_nand_explicit", .Atomic_Nand_Explicit},
		{"atomic_or_explicit", .Atomic_Or_Explicit},
		{"atomic_xor_explicit", .Atomic_Xor_Explicit},
		{"atomic_exchange_explicit", .Atomic_Exchange_Explicit},
		{"atomic_compare_exchange_strong_explicit", .Atomic_Compare_Exchange_Strong_Explicit},
		{"atomic_compare_exchange_weak_explicit", .Atomic_Compare_Exchange_Weak_Explicit},
		{"atomic_thread_fence", .Atomic_Thread_Fence},
		{"atomic_signal_fence", .Atomic_Signal_Fence},
		{"overflow_add", .Overflow_Add},
		{"overflow_sub", .Overflow_Sub},
		{"overflow_mul", .Overflow_Mul},
		{"mem_copy", .Mem_Copy},
		{"mem_copy_non_overlapping", .Mem_Copy_Non_Overlapping},
		{"mem_zero", .Mem_Zero},
		{"unaligned_load", .Unaligned_Load},
		{"unaligned_store", .Unaligned_Store},
		{"simd_extract", .Simd_Extract},
		{"simd_replace", .Simd_Replace},
		{"simd_indices", .Simd_Indices},
		{"simd_select", .Simd_Select},
		{"simd_shuffle", .Simd_Shuffle},
		{"simd_lanes_ne", .Simd_Lanes_Ne},
		{"simd_lanes_eq", .Simd_Lanes_Eq},
		{"simd_lanes_lt", .Simd_Lanes_Lt},
		{"simd_lanes_le", .Simd_Lanes_Le},
		{"simd_lanes_gt", .Simd_Lanes_Gt},
		{"simd_lanes_ge", .Simd_Lanes_Ge},
		{"simd_add", .Simd_Add},
		{"simd_sub", .Simd_Sub},
		{"simd_mul", .Simd_Mul},
		{"simd_div", .Simd_Div},
		{"simd_bit_and", .Simd_Bit_And},
		{"simd_bit_or", .Simd_Bit_Or},
		{"simd_bit_xor", .Simd_Bit_Xor},
		{"simd_bit_and_not", .Simd_Bit_And_Not},
		{"simd_min", .Simd_Min},
		{"simd_max", .Simd_Max},
		{"simd_shl", .Simd_Shl},
		{"simd_shr", .Simd_Shr},
		{"simd_shl_masked", .Simd_Shl_Masked},
		{"simd_shr_masked", .Simd_Shr_Masked},
		{"simd_reduce_or", .Simd_Reduce_Or},
		{"simd_reduce_min", .Simd_Reduce_Min},
	}
	return bindings
}

intrinsic_builtin_kind :: proc(name: string) -> Builtin_Kind {
	for binding in intrinsic_bindings() {
		if binding.name == name { return binding.kind }
	}
	return .None
}

intrinsic_scope_init :: proc(scopes: ^Scope_Store, scope: Scope_Id, package_id: Package_Id) -> Binding_Error {
	for binding in intrinsic_bindings() {
		id := entity_create(scopes, Entity{name = binding.name, kind = .Builtin, scope = scope, package_id = package_id}) or_return
		_, err := scope_insert(scopes, scope, id)
		if err != nil { return err }
	}
	return nil
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
	if checker.builtin_kinds[builtin] == .Atomic_Type_Is_Lock_Free {
		return expression_atomic_type_is_lock_free(checker, view, scope, node, arguments, call.ellipsis.kind != .Invalid)
	}
	if checker.builtin_kinds[builtin] == .Type_Merge {
		return expression_type_merge(checker, view, scope, node, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind >= .Type_Array && kind <= .Type_Elem_Type {
		return expression_type_query(checker, view, scope, node, kind, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; builtin_type_predicate_kind(kind) {
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
	if checker.builtin_kinds[builtin] == .Type_Hasher_Proc {
		return expression_type_hasher_proc(checker, view, scope, node, builtin, arguments, call.ellipsis.kind != .Invalid)
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
	if kind := checker.builtin_kinds[builtin]; kind == .Hadamard_Product || kind == .Outer_Product || kind == .Matrix_Flatten || kind == .Transpose {
		return expression_matrix_builtin(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid, hint)
	}
	if checker.builtin_kinds[builtin] == .Has_Target_Feature {
		return expression_has_target_feature(checker, view, scope, node, arguments, call.ellipsis.kind != .Invalid)
	}
	if checker.builtin_kinds[builtin] == .Procedure_Of {
		if len(arguments) != 1 || call.ellipsis.kind != .Invalid { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		specialized := check_expression(checker, view, scope, arguments[0]) or_return
		if specialized.state == .Invalid { return expression_poison(scope), nil }
		if specialized.plan == 0 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		specialized_call, is_call := checker.plans[specialized.plan].(Call_Plan)
		if !is_call || specialized_call.entity == 0 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		instance := entity_get(checker.type_checker.resolver.scopes, specialized_call.entity)
		return Expression_Info{type = instance.type, mode = .Value, entity = specialized_call.entity, scope = scope, state = .Checked}, nil
	}
	if checker.builtin_kinds[builtin] == .Soa_Zip {
		return expression_soa_zip(checker, view, scope, node, builtin, arguments, call.ellipsis.kind != .Invalid, hint)
	}
	if checker.builtin_kinds[builtin] == .Soa_Unzip {
		return expression_soa_unzip(checker, view, scope, node, builtin, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; kind == .Len || kind == .Cap {
		return expression_length(checker, view, scope, node, builtin, kind, arguments, call.ellipsis.kind != .Invalid, hint)
	}
	if checker.builtin_kinds[builtin] == .Raw_Data {
		return expression_raw_data(checker, view, scope, node, builtin, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; scalar_extra_kind(kind) {
		name := entity_get(checker.type_checker.resolver.scopes, callee.entity).name
		return expression_scalar_extra(checker, view, scope, node, builtin, kind, name, arguments, call.ellipsis.kind != .Invalid)
	}
	if kind := checker.builtin_kinds[builtin]; simd_extra_kind(kind) {
		name := entity_get(checker.type_checker.resolver.scopes, callee.entity).name
		return expression_simd_extra(checker, view, scope, node, builtin, kind, name, arguments, call.ellipsis.kind != .Invalid)
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
	if checker.builtin_kinds[builtin] == .Swizzle {
		return expression_swizzle_builtin(checker, view, file_id, scope, node, arguments, hint)
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
	if operand.type == types.TYPE_UNTYPED_STRING {
		operand = check_expression(checker, view, scope, arguments[0], types.default_type_of_untyped(store, operand.type)) or_return
		if operand.state == .Invalid { return expression_poison(scope), nil }
	}
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
	if kind == .Abs {
		operand := check_expression(checker, view, scope, arguments[0]) or_return
		if operand.state == .Invalid { return expression_poison(scope), nil }
		descriptor := types.get(store, types.resolve_named(store, operand.type))
		#partial switch descriptor.kind {
		case .Complex, .Untyped_Complex, .Quaternion, .Untyped_Quaternion:
			return expression_abs_complex(checker, view, scope, node, builtin, arguments[0], operand)
		case:
			return expression_abs_scalar(checker, view, scope, node, builtin, kind, arguments[0], operand)
		}
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
expression_abs_scalar :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	argument: syntax.Node_Index,
	operand: Expression_Info,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, operand.type))
	if operand.mode == .Type || !(conversion_integer(descriptor.kind) || conversion_float(descriptor.kind)) {
		return expression_failure(checker, view, scope, argument, .Invalid_Operand)
	}
	if operand.mode == .Constant {
		values := [1]Expression_Info{operand}
		result, failure := constant_numeric_builtin(checker.constants, store, kind, values[:], operand.type)
		if failure != nil {
			expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = operand.type, constant = result, mode = .Constant, scope = scope, state = .Checked}, nil
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	operands := make([]Operand, 1, allocator) or_return
	operands[0] = Operand(Expression_Ref{view, argument})
	plan := Plan_Id(len(checker.plans))
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = operand.type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
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

// has_target_feature folds against the global build features, even inside an
// enabled procedure: only the declaration site changes code generation. Names
// that are not x86 features fold the way an absent feature does instead of
// diagnosing, since portable `when` conditions query other architectures.
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
	names := ""
	if feature.mode == .Constant {
		constant, is_string := constant_pool_get(checker.constants, feature.constant).value.(string)
		if !is_string { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
		names = constant
	} else {
		store := checker.type_checker.store
		descriptor := types.get(store, types.resolve_named(store, feature.type))
		require, enable := "", ""
		scopes := checker.type_checker.resolver.scopes
		if feature.entity != 0 && entity_get(scopes, feature.entity).kind == .Procedure {
			require, enable = entity_target_features(checker, feature.entity) or_return
		} else if descriptor.kind == .Procedure {
			if info, info_error := expression_procedure_info(checker, descriptor.procedure_info); info_error == .None && info != nil {
				require, enable = info.require_target_feature, info.enable_target_feature
			}
		}
		is_procedure_operand := (feature.entity != 0 && entity_get(scopes, feature.entity).kind == .Procedure) || descriptor.kind == .Procedure
		if require != "" {
			names = require
		} else if enable != "" {
			names = enable
		} else {
			return expression_failure(
				checker,
				view,
				scope,
				arguments[0],
				.Invalid_Operand,
				"Expected the procedure type given to 'has_target_feature' to have @(require_target_feature=\"...\") or @(enable_target_feature=\"...\")" if is_procedure_operand else "Expected a constant string or procedure type for 'has_target_feature'",
			)
		}
	}
	_, satisfied := target_features_satisfied(types.x86_level_features(checker.microarch), names)
	constant, constant_error := constant_pool_intern_bool(checker.constants, satisfied, types.TYPE_UNTYPED_BOOL)
	if constant_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = types.TYPE_UNTYPED_BOOL, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
}

@(private = "package")
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
	if descriptor.kind == .Struct && descriptor.soa != .None {
		return expression_soa_length(checker, view, scope, node, builtin, kind, operand, arguments[0], hint)
	}
	capacity: types.Type
	if descriptor.kind == .Fixed_Capacity_Array && kind == .Cap {
		capacity = descriptor^
		capacity.kind = .Array
		descriptor = &capacity
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
	case .Slice, .Dynamic_Array, .Fixed_Capacity_Array, .Map, .String, .String16, .CString, .CString16, .Untyped_String:
		if kind == .Len && operand.mode == .Constant && operand.constant != 0 {
			length, known := constant_length(checker, operand.constant)
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
constant_length :: proc(checker: ^Expression_Checker, id: Const_Id) -> (length: int, known: bool) {
	constant := constant_pool_get(checker.constants, id)
	if constant == nil { return 0, false }
	#partial switch text in constant.value {
	case string:
		if constant.type == 0 { return len(text), true }
		store := checker.type_checker.store
		descriptor := types.get(store, types.resolve_named(store, constant.type))
		if descriptor.kind == .Slice {
			size, _, error := types.layout(store, descriptor.elem)
			if error != .None || size <= 0 { return 0, false }
			return int(i64(len(text)) / size), true
		}
		return len(text), true
	case []u16:
		return len(text), true
	case Slice_Value:
		backing := constant_pool_get(checker.constants, text.backing)
		return len(backing.value.(Aggregate_Value).elements), true
	}
	return 0, false
}

package check

// Runtime procedures that the checker resolves or that lowering calls by name. Each name is spelled once, here.
// Lowering reads the resolved entities from Runtime_Requirements.helpers, so the checker and lowering share one list.
Runtime_Helper :: enum u8 {
	None,
	Bounds_Check_Error_Contextless,
	Bounds_Check_Error_With_Context,
	Matrix_Bounds_Check_Error_Contextless,
	Matrix_Bounds_Check_Error_With_Context,
	Slice_Expr_Error_Hi_Contextless,
	Slice_Expr_Error_Hi_With_Context,
	Slice_Expr_Error_Lo_Hi_Contextless,
	Slice_Expr_Error_Lo_Hi_With_Context,
	Multi_Pointer_Slice_Expr_Error_Contextless,
	Multi_Pointer_Slice_Expr_Error_With_Context,
	Default_Hasher_Fixed,
	Default_Hasher_String,
	Default_Hasher_String16,
	Default_Hasher_Cstring,
	Default_Hasher_Cstring16,
	Default_Hasher_F64,
	Memory_Equal,
	Cstring_Eq,
	Cstring16_Eq,
	Map_Seed,
	Map_Cap,
	Map_Kvh_Data_Dynamic,
	Map_Cell_Index_Dynamic,
	Map_Hash_Is_Valid,
	Dynamic_Map_Get,
	Dynamic_Map_Set,
	Dynamic_Map_Reserve,
	Dynamic_Array_Reserve,
	Dynamic_Array_Append,
	String_Decode_Rune,
	String_Decode_Last_Rune,
	String16_Decode_Rune,
	String16_Decode_Last_Rune,
	Fixdfti,
	Fixunsdfti,
	Floattidf,
	Floattidf_Unsigned,
	Linux_Math_Fma_F32,
	Linux_Math_Fma_F64,
}

runtime_helper_names := [Runtime_Helper]string {
	.None                                        = "",
	.Bounds_Check_Error_Contextless              = "bounds_check_error_contextless",
	.Bounds_Check_Error_With_Context             = "bounds_check_error_with_context",
	.Matrix_Bounds_Check_Error_Contextless       = "matrix_bounds_check_error_contextless",
	.Matrix_Bounds_Check_Error_With_Context      = "matrix_bounds_check_error_with_context",
	.Slice_Expr_Error_Hi_Contextless             = "slice_expr_error_hi_contextless",
	.Slice_Expr_Error_Hi_With_Context            = "slice_expr_error_hi_with_context",
	.Slice_Expr_Error_Lo_Hi_Contextless          = "slice_expr_error_lo_hi_contextless",
	.Slice_Expr_Error_Lo_Hi_With_Context         = "slice_expr_error_lo_hi_with_context",
	.Multi_Pointer_Slice_Expr_Error_Contextless  = "multi_pointer_slice_expr_error_contextless",
	.Multi_Pointer_Slice_Expr_Error_With_Context = "multi_pointer_slice_expr_error_with_context",
	.Default_Hasher_Fixed                        = "default_hasher_fixed",
	.Default_Hasher_String                       = "default_hasher_string",
	.Default_Hasher_String16                     = "default_hasher_string16",
	.Default_Hasher_Cstring                      = "default_hasher_cstring",
	.Default_Hasher_Cstring16                    = "default_hasher_cstring16",
	.Default_Hasher_F64                          = "default_hasher_f64",
	.Memory_Equal                                = "memory_equal",
	.Cstring_Eq                                  = "cstring_eq",
	.Cstring16_Eq                                = "cstring16_eq",
	.Map_Seed                                    = "map_seed",
	.Map_Cap                                     = "map_cap",
	.Map_Kvh_Data_Dynamic                        = "map_kvh_data_dynamic",
	.Map_Cell_Index_Dynamic                      = "map_cell_index_dynamic",
	.Map_Hash_Is_Valid                           = "map_hash_is_valid",
	.Dynamic_Map_Get                             = "__dynamic_map_get",
	.Dynamic_Map_Set                             = "__dynamic_map_set",
	.Dynamic_Map_Reserve                         = "__dynamic_map_reserve",
	.Dynamic_Array_Reserve                       = "__dynamic_array_reserve",
	.Dynamic_Array_Append                        = "__dynamic_array_append",
	.String_Decode_Rune                          = "string_decode_rune",
	.String_Decode_Last_Rune                     = "string_decode_last_rune",
	.String16_Decode_Rune                        = "string16_decode_rune",
	.String16_Decode_Last_Rune                   = "string16_decode_last_rune",
	.Fixdfti                                     = "fixdfti",
	.Fixunsdfti                                  = "fixunsdfti",
	.Floattidf                                   = "floattidf",
	.Floattidf_Unsigned                          = "floattidf_unsigned",
	.Linux_Math_Fma_F32                          = "linux_math_fma_f32",
	.Linux_Math_Fma_F64                          = "linux_math_fma_f64",
}

// The runtime-scope entity for a helper, or 0 when the runtime package does not define it.
@(private = "package")
runtime_helper_entity :: proc(checker: ^Expression_Checker, helper: Runtime_Helper) -> Entity_Id {
	collection := checker.type_checker.collection
	if helper == .None || collection == nil || collection.runtime_scope == 0 { return 0 }
	return scope_lookup_current(checker.type_checker.resolver.scopes, collection.runtime_scope, runtime_helper_names[helper])
}

@(private = "package")
runtime_helper_entities :: proc(checker: ^Expression_Checker) -> (helpers: [Runtime_Helper]Entity_Id) {
	for helper in Runtime_Helper {
		helpers[helper] = runtime_helper_entity(checker, helper)
	}
	return helpers
}

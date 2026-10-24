package check

import "base:runtime"
import "core:fmt"
import "core:mem"
import "oc:types"

// Runtime procedures that generated map hashers and equality procedures call.
map_helper_names := [?]Runtime_Helper {
	.Default_Hasher_Fixed,
	.Default_Hasher_String,
	.Default_Hasher_String16,
	.Default_Hasher_Cstring,
	.Default_Hasher_Cstring16,
	.Default_Hasher_F64,
	.Memory_Equal,
	.Cstring_Eq,
	.Cstring16_Eq,
}
map_runtime_helper_names := [?]Runtime_Helper {
	.Map_Seed,
	.Map_Cap,
	.Map_Kvh_Data_Dynamic,
	.Map_Cell_Index_Dynamic,
	.Map_Hash_Is_Valid,
	.Dynamic_Map_Get,
	.Dynamic_Map_Set,
	.Dynamic_Map_Reserve,
}

// Queues runtime procedures the way upstream's add_package_dependency does: resolving
// their bodies so publish emits a symbol lowering can call. Used for helpers that no
// user code names, such as the ones non-empty dynamic literals call.
@(private = "package")
expression_resolve_runtime_helpers :: proc(checker: ^Expression_Checker, helpers: []Runtime_Helper) -> (resolved: bool, err: Resolve_Error) {
	collection := checker.type_checker.collection
	if collection == nil || collection.runtime_scope == 0 { return false, nil }
	scopes := checker.type_checker.resolver.scopes
	for kind in helpers {
		helper := runtime_helper_entity(checker, kind)
		if helper == 0 { return false, nil }
		_, resolve_error := resolve_entity(checker.type_checker.resolver, helper)
		if resolve_error != nil { return false, resolve_error }
		if entity_get(scopes, helper).state != .Resolved { return false, nil }
	}
	return true, nil
}

@(private = "package")
expression_resolve_bounds_helpers :: proc(checker: ^Expression_Checker) -> Resolve_Error {
	collection := checker.type_checker.collection
	if collection == nil || collection.runtime_scope == 0 { return nil }
	names := [?]Runtime_Helper {
		.Bounds_Check_Error_Contextless,
		.Bounds_Check_Error_With_Context,
		.Matrix_Bounds_Check_Error_Contextless,
		.Matrix_Bounds_Check_Error_With_Context,
		.Slice_Expr_Error_Hi_Contextless,
		.Slice_Expr_Error_Hi_With_Context,
		.Slice_Expr_Error_Lo_Hi_Contextless,
		.Slice_Expr_Error_Lo_Hi_With_Context,
		.Multi_Pointer_Slice_Expr_Error_Contextless,
		.Multi_Pointer_Slice_Expr_Error_With_Context,
	}
	_, err := expression_resolve_runtime_helpers(checker, names[:])
	return err
}

@(private = "package")
expression_resolve_map_helpers :: proc(checker: ^Expression_Checker) -> (resolved: bool, err: Resolve_Error) {
	resolved, err = expression_resolve_runtime_helpers(checker, map_runtime_helper_names[:])
	if err != nil || !resolved { return resolved, err }
	scopes := checker.type_checker.resolver.scopes
	for kind in map_helper_names {
		helper := runtime_helper_entity(checker, kind)
		if helper == 0 { continue }
		_, resolve_error := resolve_entity(checker.type_checker.resolver, helper)
		if resolve_error != nil { return false, resolve_error }
		if entity_get(scopes, helper).state != .Resolved { return false, nil }
	}
	return true, nil
}

// Types whose equality or hashing the generator cannot express are rejected at plan time, for both map keys and comparisons.
generator_supported :: proc(store: ^types.Store, type: types.Type_Id) -> bool {
	descriptor := types.get(store, types.resolve_named(store, type))
	#partial switch descriptor.kind {
	case .Any, .Slice, .Dynamic_Array, .Fixed_Capacity_Array, .Map:
		return false
	case .Struct:
		fields := descriptor.fields
		for field in fields {
			if !generator_supported(store, field.type) { return false }
		}
	case .Union:
		variants := descriptor.variants
		for variant in variants {
			if !generator_supported(store, variant) { return false }
		}
	case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
		return generator_supported(store, descriptor.elem)
	}
	return true
}

// One generated equality procedure per union compared through == or != at runtime.
@(private = "package")
expression_checker_publish_comparison_procedures :: proc(checker: ^Expression_Checker) -> runtime.Allocator_Error {
	for plan in checker.plans {
		comparison, is_comparison := plan.(Comparison_Plan)
		if !is_comparison { continue }
		map_generated_procedure(checker, .Equality, comparison.type) or_return
	}
	return nil
}

@(private = "package")
expression_checker_publish_map_info :: proc(checker: ^Expression_Checker, program: ^Checked_Program) -> runtime.Allocator_Error {
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	store := checker.type_checker.store
	entries := make([dynamic]Map_Info_Entry, allocator) or_return
	for plan in checker.plans {
		info, is_info := plan.(Map_Info_Plan)
		if !is_info { continue }
		append_map_info_entry(checker, &entries, program, info.type) or_return
	}
	// Maps that only surface through runtime type info (printed or reflected but
	// never indexed) still need map info, like upstream's on-demand map info.
	for info in program.runtime.type_info {
		map_type := types.resolve_named(store, info.type)
		if types.get(store, map_type).kind != .Map { continue }
		append_map_info_entry(checker, &entries, program, map_type) or_return
	}
	program.runtime.map_info = entries[:]
	program.runtime.helpers = runtime_helper_entities(checker)
	return nil
}

@(private = "file")
append_map_info_entry :: proc(
	checker: ^Expression_Checker,
	entries: ^[dynamic]Map_Info_Entry,
	program: ^Checked_Program,
	map_type: types.Type_Id,
) -> runtime.Allocator_Error {
	if map_info_index(entries[:], map_type) >= 0 { return nil }
	store := checker.type_checker.store
	descriptor := types.get(store, map_type)^
	if !generator_supported(store, descriptor.index) { return nil }
	key_hasher := map_generated_procedure(checker, .Hasher, descriptor.index) or_return
	key_equal := map_generated_procedure(checker, .Equality, descriptor.index) or_return
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	name := fmt.aprintf("__odinc_internal_map_info_%d", len(entries), allocator = allocator)
	append(&checker.symbols, Symbol{kind = .Global, name = name}) or_return
	append(
		entries,
		Map_Info_Entry {
			type = map_type,
			key_cell = map_cell_info_symbol(program, descriptor.index),
			value_cell = map_cell_info_symbol(program, descriptor.elem),
			key_hasher = key_hasher,
			key_equal = key_equal,
			symbol = Symbol_Id(len(checker.symbols) - 1),
		},
	) or_return
	return nil
}

@(private = "file")
map_info_index :: proc(entries: []Map_Info_Entry, type: types.Type_Id) -> int {
	for entry, index in entries {
		if entry.type == type { return index }
	}
	return -1
}

@(private = "file")
map_cell_info_symbol :: proc(program: ^Checked_Program, type: types.Type_Id) -> Symbol_Id {
	for entry in program.runtime.map_cell_info {
		if entry.type == type { return entry.symbol }
	}
	return 0
}

// One generated procedure per kind and type, shared by every map that needs it.
@(private = "package")
map_generated_procedure :: proc(
	checker: ^Expression_Checker,
	kind: Generated_Body_Kind,
	type: types.Type_Id,
) -> (
	symbol: Symbol_Id,
	err: runtime.Allocator_Error,
) {
	for procedure in checker.procedures {
		if procedure.generated == (Generated_Body{kind = kind, type = type}) { return procedure.symbol, nil }
	}
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	store := checker.type_checker.store
	signature := map_generated_signature(store, kind, allocator) or_return
	prefix := "hasher" if kind == .Hasher else "equal"
	name := fmt.aprintf("__odinc_internal_map_%s_%d", prefix, len(checker.symbols), allocator = allocator)
	append(&checker.symbols, Symbol{kind = .Procedure, name = name, type = signature, linkage = .Internal}) or_return
	append(
		&checker.procedures,
		Checked_Procedure {
			symbol = Symbol_Id(len(checker.symbols) - 1),
			signature = signature,
			generated = {kind = kind, type = type},
			convention = .Contextless,
		},
	) or_return
	return Symbol_Id(len(checker.symbols) - 1), nil
}

@(private = "package")
map_generated_signature :: proc(store: ^types.Store, kind: Generated_Body_Kind, allocator: runtime.Allocator) -> (types.Type_Id, runtime.Allocator_Error) {
	raw := types.intern(store, types.Type{kind = .Raw_Pointer})
	params, params_error := make([]types.Type_Id, 2, allocator)
	if params_error != nil { return types.TYPE_NONE, params_error }
	params[0] = raw
	result: types.Type_Id
	if kind == .Hasher {
		params[1] = types.intern(store, types.Type{kind = .Integer, name = "uintptr", count = 8})
		result = params[1]
	} else {
		params[1] = raw
		result = types.intern(store, types.Type{kind = .Bool})
	}
	results, results_error := make([]types.Type_Id, 1, allocator)
	if results_error != nil { return types.TYPE_NONE, results_error }
	results[0] = result
	signature := types.intern(store, types.Type{kind = .Procedure, convention = .Contextless, params = params, results = results})
	return signature, nil
}

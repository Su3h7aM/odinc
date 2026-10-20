package check

import "base:runtime"
import "core:fmt"
import "core:mem"
import "oc:types"

// Runtime procedures that generated map hashers and equality procedures call.
map_helper_names := [?]string{"default_hasher_fixed", "default_hasher_string", "default_hasher_string16", "default_hasher_f64", "memory_equal"}
map_runtime_helper_names := [?]string{"map_seed_from_map_data", "__dynamic_map_get"}

@(private = "package")
expression_resolve_map_helpers :: proc(checker: ^Expression_Checker) -> (resolved: bool, err: Resolve_Error) {
	collection := checker.type_checker.collection
	if collection == nil || collection.runtime_scope == 0 { return false, nil }
	scopes := checker.type_checker.resolver.scopes
	for name in map_runtime_helper_names {
		helper := scope_lookup_current(scopes, collection.runtime_scope, name)
		if helper == 0 { return false, nil }
		_, resolve_error := resolve_entity(checker.type_checker.resolver, helper)
		if resolve_error != nil { return false, resolve_error }
		if entity_get(scopes, helper).state != .Resolved { return false, nil }
	}
	for name in map_helper_names {
		helper := scope_lookup_current(scopes, collection.runtime_scope, name)
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
	case .Any, .CString, .CString16, .Slice, .Dynamic_Array, .Fixed_Capacity_Array, .Map:
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
		if !is_info || map_info_index(entries[:], info.type) >= 0 { continue }
		key := types.get(store, info.type).index
		value := types.get(store, info.type).elem
		key_hasher := map_generated_procedure(checker, .Hasher, key) or_return
		key_equal := map_generated_procedure(checker, .Equality, key) or_return
		name := fmt.aprintf("__odinc_internal_map_info_%d", len(entries), allocator = allocator)
		append(&checker.symbols, Symbol{kind = .Global, name = name}) or_return
		append(
			&entries,
			Map_Info_Entry {
				type = info.type,
				key_cell = map_cell_info_symbol(program, key),
				value_cell = map_cell_info_symbol(program, value),
				key_hasher = key_hasher,
				key_equal = key_equal,
				symbol = Symbol_Id(len(checker.symbols) - 1),
			},
		) or_return
	}
	program.runtime.map_info = entries[:]
	program.runtime.helper_entities = map_helper_entities(checker) or_return
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

@(private = "file")
map_helper_entities :: proc(checker: ^Expression_Checker) -> (helpers: []Entity_Id, err: runtime.Allocator_Error) {
	collection := checker.type_checker.collection
	if collection == nil || collection.runtime_scope == 0 { return nil, nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	scopes := checker.type_checker.resolver.scopes
	list := make([dynamic]Entity_Id, allocator) or_return
	for name in map_runtime_helper_names {
		helper := scope_lookup_current(scopes, collection.runtime_scope, name)
		if helper != 0 { append(&list, helper) or_return }
	}
	for name in map_helper_names {
		helper := scope_lookup_current(scopes, collection.runtime_scope, name)
		if helper != 0 { append(&list, helper) or_return }
	}
	for name in range_helper_names {
		helper := scope_lookup_current(scopes, collection.runtime_scope, name)
		if helper != 0 { append(&list, helper) or_return }
	}
	return list[:], nil
}

// One generated procedure per kind and type, shared by every map that needs it.
@(private = "file")
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

@(private = "file")
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

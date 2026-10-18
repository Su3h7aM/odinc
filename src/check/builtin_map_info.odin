package check

import "base:runtime"
import "core:fmt"
import "core:mem"
import "oc:syntax"
import "oc:types"

// Map cells pack whole elements into one cache line; base:runtime's MAP_CACHE_LINE_SIZE must match.
MAP_CELL_CACHE_LINE_SIZE :: 64

Map_Info_Plan :: struct {
	type: types.Type_Id,
}

Map_Cell_Info_Plan :: struct {
	type: types.Type_Id,
}

Map_Cell_Info_Entry :: struct {
	type:              types.Type_Id,
	size_of_type:      i64,
	align_of_type:     i64,
	size_of_cell:      i64,
	elements_per_cell: i64,
	symbol:            Symbol_Id,
}

Map_Info_Entry :: struct {
	type:                          types.Type_Id,
	key_cell, value_cell:          Symbol_Id,
	key_hasher, key_equal, symbol: Symbol_Id,
}

@(private = "package")
expression_map_info :: proc(
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
	if len(arguments) != 1 || ellipsis { return expression_unsupported(checker, view, scope, node, "Map_Info_Arguments") }
	operand := check_expression(checker, view, scope, arguments[0]) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	if operand.mode != .Type { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	store := checker.type_checker.store
	resolved := types.resolve_named(store, operand.type)
	info_name := "Map_Cell_Info"
	if kind == .Type_Map_Info {
		descriptor := types.get(store, resolved)
		if descriptor.kind != .Map { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
		if !generator_supported(store, descriptor.index) { return expression_unsupported(checker, view, scope, node, "Map_Info_Key") }
		helpers_resolved, helper_error := expression_resolve_map_helpers(checker)
		if helper_error != nil { return {}, helper_error }
		if !helpers_resolved { return expression_unsupported(checker, view, scope, node, "Map_Info_Helpers") }
		info_name = "Map_Info"
	} else if _, _, layout_error := types.layout(store, resolved); layout_error != .None {
		return expression_unsupported(checker, view, scope, node, "Map_Cell_Info_Layout")
	}
	info_type := runtime_type_named(checker, info_name)
	if info_type == types.TYPE_NONE { return expression_unsupported(checker, view, scope, node, "Map_Info_Runtime") }
	plan := Plan_Id(len(checker.plans))
	if kind == .Type_Map_Info {
		append(&checker.plans, Plan(Map_Info_Plan{type = resolved})) or_return
	} else {
		append(&checker.plans, Plan(Map_Cell_Info_Plan{type = resolved})) or_return
	}
	result := types.intern(store, types.Type{kind = .Pointer, elem = info_type})
	return Expression_Info{type = result, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

// One entry per cell type a plan needs, in first-use order, each with its own global symbol.
@(private = "package")
expression_checker_publish_map_cell_info :: proc(checker: ^Expression_Checker, program: ^Checked_Program) -> runtime.Allocator_Error {
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	entries := make([dynamic]Map_Cell_Info_Entry, allocator) or_return
	for plan in checker.plans {
		#partial switch requested in plan {
		case Map_Cell_Info_Plan:
			append_map_cell_info_entry(checker, &entries, requested.type) or_return
		case Map_Info_Plan:
			key := types.get(checker.type_checker.store, requested.type).index
			value := types.get(checker.type_checker.store, requested.type).elem
			append_map_cell_info_entry(checker, &entries, key) or_return
			append_map_cell_info_entry(checker, &entries, value) or_return
		}
	}
	program.runtime.map_cell_info = entries[:]
	return nil
}

@(private = "file")
append_map_cell_info_entry :: proc(checker: ^Expression_Checker, entries: ^[dynamic]Map_Cell_Info_Entry, type: types.Type_Id) -> runtime.Allocator_Error {
	if map_cell_info_index(entries[:], type) >= 0 { return nil }
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	size, alignment, _ := types.layout(checker.type_checker.store, type)
	cell_size, elements := map_cell_size_and_len(size)
	name := fmt.aprintf("__odinc_internal_map_cell_info_%d", len(entries), allocator = allocator)
	append(&checker.symbols, Symbol{kind = .Global, name = name}) or_return
	append(
		entries,
		Map_Cell_Info_Entry {
			type = type,
			size_of_type = size,
			align_of_type = alignment,
			size_of_cell = cell_size,
			elements_per_cell = elements,
			symbol = Symbol_Id(len(checker.symbols) - 1),
		},
	) or_return
	return nil
}

@(private = "file")
map_cell_info_index :: proc(entries: []Map_Cell_Info_Entry, type: types.Type_Id) -> int {
	for entry, index in entries {
		if entry.type == type { return index }
	}
	return -1
}

// Port of map_cell_size_and_len (check_type.cpp:4301): the cell size is rounded up to the cache line.
@(private = "file")
map_cell_size_and_len :: proc(element_size: i64) -> (size, length: i64) {
	length = 1
	if 0 < element_size && element_size < MAP_CELL_CACHE_LINE_SIZE {
		length = MAP_CELL_CACHE_LINE_SIZE / element_size
	}
	size = (element_size * length + MAP_CELL_CACHE_LINE_SIZE - 1) / MAP_CELL_CACHE_LINE_SIZE * MAP_CELL_CACHE_LINE_SIZE
	return
}

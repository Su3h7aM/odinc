package lower

import "base:runtime"
import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"

// Four uintptr fields: size_of_type, align_of_type, size_of_cell, elements_per_cell.
MAP_CELL_INFO_SIZE :: 32

// Four pointer-sized fields: key and value cell info, then the key hasher and key equality procedures.
MAP_INFO_SIZE :: 32

@(private)
fill_map_cell_info :: proc(program: ^check.Checked_Program, module: ^ir.Module, symbols: []ir.Symbol_Ref) -> runtime.Allocator_Error {
	allocator := virtual.arena_allocator(&module.arena)
	for entry in check.runtime_requirements(program).map_cell_info {
		assert(int(entry.symbol) > 0 && int(entry.symbol) < len(symbols))
		symbol := symbols[entry.symbol]
		assert(symbol.space == .Global)
		global := &module.globals[symbol.index]
		global.size = MAP_CELL_INFO_SIZE
		global.align = 8
		global.mutable = false
		global.bytes = make([]byte, MAP_CELL_INFO_SIZE, allocator) or_return
		write_scalar(global.bytes, 0, u64(entry.size_of_type), 8)
		write_scalar(global.bytes, 8, u64(entry.align_of_type), 8)
		write_scalar(global.bytes, 16, u64(entry.size_of_cell), 8)
		write_scalar(global.bytes, 24, u64(entry.elements_per_cell), 8)
	}
	return nil
}

@(private)
lower_map_cell_info_of :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Map_Cell_Info_Plan) -> ir.Node_Id {
	for entry in check.runtime_requirements(state.job.program).map_cell_info {
		if entry.type == plan.type {
			return ir.symbol_addr(state.job.function, state.job.symbols[entry.symbol])
		}
	}
	return lower_fail(state, node, .Builtin)
}

@(private)
fill_map_info :: proc(program: ^check.Checked_Program, module: ^ir.Module, symbols: []ir.Symbol_Ref) -> runtime.Allocator_Error {
	allocator := virtual.arena_allocator(&module.arena)
	for entry in check.runtime_requirements(program).map_info {
		symbol := symbols[entry.symbol]
		assert(symbol.space == .Global)
		global := &module.globals[symbol.index]
		global.size = MAP_INFO_SIZE
		global.align = 8
		global.mutable = false
		global.bytes = make([]byte, MAP_INFO_SIZE, allocator) or_return
		global.relocs = make([]ir.Data_Reloc, 4, allocator) or_return
		global.relocs[0] = {
			offset = 0,
			target = symbols[entry.key_cell],
		}
		global.relocs[1] = {
			offset = 8,
			target = symbols[entry.value_cell],
		}
		global.relocs[2] = {
			offset = 16,
			target = symbols[entry.key_hasher],
		}
		global.relocs[3] = {
			offset = 24,
			target = symbols[entry.key_equal],
		}
	}
	return nil
}

@(private)
lower_map_info_of :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Map_Info_Plan) -> ir.Node_Id {
	for entry in check.runtime_requirements(state.job.program).map_info {
		if entry.type == plan.type {
			return ir.symbol_addr(state.job.function, state.job.symbols[entry.symbol])
		}
	}
	return lower_fail(state, node, .Builtin)
}

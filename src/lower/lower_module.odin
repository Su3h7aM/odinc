package lower

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "oc:check"
import "oc:ir"
import "oc:types"

@(private)
declare_symbols :: proc(
	program: ^check.Checked_Program,
	module: ^ir.Module,
	allocator: runtime.Allocator,
) -> (
	symbols: []ir.Symbol_Ref,
	err: runtime.Allocator_Error,
) {
	module_allocator := virtual.arena_allocator(&module.arena)
	entries := check.symbols(program)
	symbols = make([]ir.Symbol_Ref, len(entries) + 1, module_allocator) or_return
	for symbol, index in entries {
		switch symbol.kind {
		case .None:
			assert(false, "unresolved checker symbol")
		case .Procedure:
			function_index := u32(len(module.functions))
			function := ir.function_make(allocator, ir.Function_Id(function_index), symbol.name, 0) or_return
			if _, append_error := append(&module.functions, function); append_error != nil {
				ir.function_destroy(function)
				return nil, append_error
			}
			symbols[index + 1] = {.Function, function_index}
		case .Global:
			symbols[index + 1] = {.Global, u32(len(module.globals))}
			append(
				&module.globals,
				ir.Global{name = strings.clone(symbol.name, module_allocator) or_return, align = symbol.alignment, mutable = true, tls = symbol.thread_local},
			) or_return
		case .Extern:
			symbols[index + 1] = {.Extern, u32(len(module.externs))}
			append(&module.externs, ir.Extern{name = strings.clone(symbol.name, module_allocator) or_return}) or_return
		}
	}
	return symbols, nil
}

@(private)
fill_globals :: proc(
	program: ^check.Checked_Program,
	module: ^ir.Module,
	symbols: []ir.Symbol_Ref,
	errors: ^[dynamic]Lower_Error,
) -> (
	err: runtime.Allocator_Error,
) {
	allocator := virtual.arena_allocator(&module.arena)
	for global in check.globals(program) {
		assert(int(global.symbol) > 0 && int(global.symbol) < len(symbols))
		symbol := symbols[global.symbol]
		assert(symbol.space == .Global)
		output := &module.globals[symbol.index]
		size, alignment, layout_error := types.layout(check.type_store(program), global.type)
		assert(layout_error == .None, "incomplete checked global type")
		assert(size >= 0 && size <= i64(max(u32)) && alignment <= i64(max(u32)))
		output.size = u32(size)
		output.align = max(output.align, u32(alignment), global.alignment)
		output.tls = output.tls || global.thread_local
		output.relocs = make([]ir.Data_Reloc, len(global.relocations), allocator) or_return
		for relocation, index in global.relocations {
			assert(int(relocation.target) > 0 && int(relocation.target) < len(symbols))
			assert(size >= 8 && relocation.offset <= u64(size - 8))
			output.relocs[index] = {u32(relocation.offset), symbols[relocation.target], relocation.addend}
		}
		if global.dynamic_initializer {
			append(errors, Lower_Error{code = .Unsupported, feature = .Global_Initializer, entity = global.entity}) or_return
		} else if global.initializer != 0 {
			bytes, relocs, encoded, image_error := global_constant_image(program, global.initializer, output.size, symbols, output.relocs, allocator)
			if image_error != nil { return image_error }
			if !encoded {
				append(errors, Lower_Error{code = .Unsupported, feature = .Global_Initializer, entity = global.entity}) or_return
				continue
			}
			output.bytes = bytes
			output.relocs = relocs
		}
	}
	return nil
}

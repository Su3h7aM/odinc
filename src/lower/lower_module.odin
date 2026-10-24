package lower

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "oc:check"
import "oc:ir"
import "oc:types"

@(private)
declare_symbols :: proc(program: ^check.Checked_Program, module: ^ir.Module) -> (symbols: []ir.Symbol_Ref, err: runtime.Allocator_Error) {
	module_allocator := virtual.arena_allocator(&module.arena)
	entries := check.symbols(program)
	symbols = make([]ir.Symbol_Ref, len(entries) + 1, module_allocator) or_return
	for symbol, index in entries {
		switch symbol.kind {
		case .None:
			assert(false, "unresolved checker symbol")
		case .Procedure:
			function_index := u32(len(module.functions))
			append(&module.functions, nil) or_return
			symbols[index + 1] = {.Function, function_index}
		case .Global:
			symbols[index + 1] = {.Global, u32(len(module.globals))}
			append(
				&module.globals,
				ir.Global {
					name = strings.clone(symbol.name, module_allocator) or_return,
					linkage = lower_symbol_linkage(symbol.linkage),
					align = symbol.alignment,
					mutable = true,
					tls = symbol.thread_local,
				},
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
		if global.initializer != 0 {
			if text, is_string := check.constant(program, global.initializer).value.(string); is_string {
				bytes: []byte
				relocs: []ir.Data_Reloc
				string_error: runtime.Allocator_Error
				if types.get(check.type_store(program), types.resolve_named(check.type_store(program), global.type)).kind == .CString {
					bytes, relocs, string_error = global_cstring_image(module, text, output.relocs, allocator)
				} else {
					bytes, relocs, string_error = global_load_image(module, program, global.type, text, output.relocs, allocator)
				}
				if string_error != nil { return string_error }
				output = &module.globals[symbol.index]
				output.bytes = bytes
				output.relocs = relocs
				continue
			}
			bytes, relocs, encoded, image_error := global_constant_image(
				Image_Sink{module = module},
				program,
				global.initializer,
				output.size,
				symbols,
				output.relocs,
				allocator,
			)
			if image_error != nil { return image_error }
			output = &module.globals[symbol.index]
			if !encoded {
				declaration := program.entities[global.entity].declaration
				span := program.files[declaration.file].ast.nodes[declaration.node]
				source := check.Source_Span {
					file  = declaration.file,
					start = span.start,
					end   = span.end,
				}
				append(errors, Lower_Error{code = .Unsupported, feature = .Global_Initializer, entity = global.entity, source = source}) or_return
				continue
			}
			output.bytes = bytes
			output.relocs = relocs
		}
	}
	return nil
}

@(private)
lower_symbol_linkage :: proc(linkage: check.Linkage) -> ir.Linkage {
	switch linkage {
	case .Internal:
		return .Internal
	case .Strong:
		return .Strong
	case .Weak:
		return .Weak
	case .Link_Once:
		return .Link_Once
	}
	unreachable()
}

package link

import "base:runtime"
import "oc:elf"

/*
	Adds the defined symbols to `builder`: every local, and each global or
	weak name whose chosen definition is this symbol.  Absolute, discarded,
	undefined and thread-local symbols are skipped.
*/
add_symbol_table :: proc(builder: ^elf.Executable_Builder, inputs: []Input, addresses: [][]u64, choices: map[string]Symbol_Choice) -> runtime.Allocator_Error {
	for input, input_index in inputs {
		for symbol, symbol_index in input.symbols {
			if len(symbol.name) == 0 || symbol.absolute || symbol.atom == ATOM_UNDEFINED || int(symbol.atom) >= len(input.atoms) {
				continue
			}
			atom := input.atoms[symbol.atom]
			if atom.discarded || atom.section == .Tdata || atom.section == .Tbss {
				continue
			}
			binding := elf.STB.STB_LOCAL
			if symbol.binding != .Local {
				choice, chosen := choices[symbol.name]
				if !chosen || choice != (Symbol_Choice{input = u32(input_index), symbol = u32(symbol_index)}) {
					continue
				}
				binding = symbol.binding == .Weak ? elf.STB.STB_WEAK : elf.STB.STB_GLOBAL
			}
			kind := elf.STT.STT_OBJECT
			if atom.section == .Text {
				kind = elf.STT.STT_FUNC
			}
			size := u64(len(atom.bytes))
			if atom.size > size {
				size = atom.size
			}
			if symbol.offset != 0 {
				size = 0
			}
			elf.executable_add_symbol(builder, symbol.name, binding, kind, addresses[input_index][symbol.atom] + symbol.offset, size) or_return
		}
	}
	return nil
}

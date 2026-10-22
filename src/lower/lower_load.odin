package lower

import "base:runtime"
import "oc:check"
import "oc:ir"
import "oc:types"

@(private)
global_load_image :: proc(
	module: ^ir.Module,
	program: ^check.Checked_Program,
	type: types.Type_Id,
	text: string,
	relocs: []ir.Data_Reloc,
	allocator: runtime.Allocator,
) -> (
	bytes: []byte,
	out_relocs: []ir.Data_Reloc,
	err: runtime.Allocator_Error,
) {
	bytes, out_relocs = global_string_image(module, text, relocs, allocator) or_return
	store := check.type_store(program)
	descriptor := types.get(store, types.resolve_named(store, type))
	if descriptor.kind == .Slice {
		size, alignment, error := types.layout(store, descriptor.elem)
		assert(error == .None && size > 0)
		write_scalar(bytes, 8, u64(i64(len(text)) / size), 8)
		if len(text) != 0 {
			module.globals[out_relocs[len(out_relocs) - 1].target.index].align = u32(alignment)
		}
	}
	return bytes, out_relocs, nil
}

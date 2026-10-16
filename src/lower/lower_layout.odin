package lower

import "base:runtime"
import "oc:types"

@(private)
Type_Layout :: struct {
	size, align: i64,
	error:       types.Layout_Error,
}

@(private)
prepare_layouts :: proc(store: ^types.Store, allocator: runtime.Allocator) -> (layouts: []Type_Layout, err: runtime.Allocator_Error) {
	layouts = make([]Type_Layout, len(store.types), allocator) or_return
	for _, index in store.types {
		if index == 0 { continue }
		type := types.Type_Id(index)
		layout := &layouts[index]
		layout.size, layout.align, layout.error = types.layout(store, type)
		if layout.error != .None { continue }
	}
	return layouts, nil
}

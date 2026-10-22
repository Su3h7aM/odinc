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
		layout := &layouts[index]
		layout.size, layout.align, layout.error = types.layout(store, types.Type_Id(index))
	}
	// A failed layout resets every layout state, so the valid types are laid out again once no failure follows.
	for layout, index in layouts {
		if index != 0 && layout.error == .None {
			_, _, _ = types.layout(store, types.Type_Id(index))
		}
	}
	return layouts, nil
}

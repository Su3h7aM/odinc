package lower

import "core:fmt"
import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// A slice value is its header {data, length} in the frame. The backing array is in the frame, or static storage for
// package-level initializers, which run once; an empty literal is a nil slice.
@(private)
lower_slice_literal :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Slice_Literal_Plan) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	function := state.job.function
	count := types.get(check.type_store(state.job.program), plan.backing.type).count
	data := ir.const_int(function, .Ptr, 0)
	if count > 0 {
		data = lower_slice_backing(state, node, plan.backing)
		if state.failed || function.error != nil { return 0 }
	}
	header := ir.stack_slot(function, state.entry_control, 16, 8)
	lower_store_word(state, header, data)
	lower_store_word(state, ir.ptr_offset(function, header, 8), ir.const_int(function, .I64, count))
	return header
}

@(private = "file")
lower_slice_backing :: proc(state: ^Procedure_State, node: syntax.Node_Index, backing: check.Aggregate_Plan) -> ir.Node_Id {
	module := state.job.module
	// Static storage is only for package-level initializers, which run once; generated startup procedures have no
	// procedure entity, while every real procedure body keeps the backing in its frame. The module alone cannot tell
	// them apart, since it is present in every procedure body.
	if module == nil || state.job.procedure.entity != 0 { return lower_aggregate(state, node, backing) }
	layout := state.job.layouts[backing.type]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, node, .Expression) }
	index := len(module.globals)
	name := fmt.aprintf("__odinc_internal_slice_backing_%d", index, allocator = virtual.arena_allocator(&module.arena))
	if _, error := append(&module.globals, ir.Global{name = name, size = u32(layout.size), align = u32(layout.align), mutable = true, anonymous = true});
	   error != nil {
		state.job.allocation_error = error
		state.failed = true
		return 0
	}
	address := ir.symbol_addr(state.job.function, ir.Symbol_Ref{space = .Global, index = u32(index)})
	return lower_aggregate_into(state, node, backing, address, layout.size)
}

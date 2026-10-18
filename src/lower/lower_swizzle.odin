package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_swizzle_destination :: proc(state: ^Procedure_State, plan: check.Swizzle_Plan, type: types.Type_Id) -> Assignment_Destination {
	result := Assignment_Destination {
		type       = type,
		lane_count = plan.count,
	}
	descriptor := lower_type(state, operand_type(state, plan.root))
	if plan.indirect { descriptor = lower_type(state, descriptor.elem) }
	stride := state.job.layouts[descriptor.elem].size
	if root, ok := plan.root.(check.Expression_Ref); ok && !plan.indirect {
		previous_view := state.view
		state.view = root.view
		defer state.view = previous_view
		for state.ast.nodes[root.node].kind == .Paren_Expr { root.node = state.ast.nodes[root.node].payload.(syntax.Paren_Expr).expr }
		info := lower_info(state, root.node)
		if info.plan != 0 {
			if nested, found := check.plan(state.job.program, info.plan)^.(check.Swizzle_Plan); found {
				backing := lower_swizzle_destination(state, nested, info.type)
				for index in 0 ..< int(plan.count) { result.lanes[index] = backing.lanes[plan.indices[index]] }
				return result
			}
		}
	}
	base := lower_operand(state, plan.root)
	for index in 0 ..< int(plan.count) { result.lanes[index] = ir.ptr_offset(state.job.function, base, i64(plan.indices[index]) * stride) }
	return result
}

@(private)
lower_swizzle_read :: proc(state: ^Procedure_State, destination: Assignment_Destination) -> ir.Node_Id {
	if destination.lane_count == 1 { return lower_load(state, destination.lanes[0], destination.type) }
	descriptor := lower_type(state, destination.type)
	layout := state.job.layouts[destination.type]
	result := ir.stack_slot(state.job.function, state.entry_control, u32(layout.size), u32(layout.align))
	stride := state.job.layouts[descriptor.elem].size
	for index in 0 ..< int(destination.lane_count) {
		value := lower_load(state, destination.lanes[index], descriptor.elem)
		lower_store(state, ir.ptr_offset(state.job.function, result, i64(index) * stride), value, descriptor.elem)
	}
	return result
}

@(private)
lower_swizzle_write :: proc(state: ^Procedure_State, destination: Assignment_Destination, value: ir.Node_Id) {
	if destination.lane_count == 1 { lower_store(state, destination.lanes[0], value, destination.type); return }
	descriptor := lower_type(state, destination.type)
	stride := state.job.layouts[descriptor.elem].size
	values: [4]ir.Node_Id
	for index in 0 ..< int(destination.lane_count) { values[index] = lower_load(state, ir.ptr_offset(state.job.function, value, i64(index) * stride), descriptor.elem) }
	for index in 0 ..< int(destination.lane_count) { lower_store(state, destination.lanes[index], values[index], descriptor.elem) }
}

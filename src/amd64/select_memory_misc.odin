package amd64

import "oc:ir"

@(private)
select_memory_misc :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	#partial switch ir.Target_Op(selector.input.nodes.data[node].index) {
	case .Pause:
		return emit(selector.output, selector.block, .PAUSE, 0)
	case .Debug_Trap:
		return emit(selector.output, selector.block, .INT3, 0)
	case .Cpuid:
		return select_fixed_target_op(selector, node, .CPUID, []Gpr{.RAX, .RCX}, []Gpr{.RAX, .RBX, .RCX, .RDX})
	case .Xgetbv:
		return select_fixed_target_op(selector, node, .XGETBV, []Gpr{.RCX}, []Gpr{.RAX, .RDX})
	case .Rdtsc:
		return select_read_cycle_counter(selector, node)
	}
	return select_failure(selector)
}

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
	case .Aesenc:
		return select_simd_target_op(selector, node, .AESENC)
	case .Aesenclast:
		return select_simd_target_op(selector, node, .AESENCLAST)
	case .Aesimc:
		return select_simd_target_op(selector, node, .AESIMC)
	case .Aeskeygenassist:
		return select_simd_target_op(selector, node, .AESKEYGENASSIST)
	case .Aesdec:
		return select_simd_target_op(selector, node, .AESDEC)
	case .Aesdeclast:
		return select_simd_target_op(selector, node, .AESDECLAST)
	case .Pshufb:
		return select_simd_target_op(selector, node, .PSHUFB)
	case .Pclmulqdq:
		return select_simd_target_op(selector, node, .PCLMULQDQ)
	case .Sha256msg1:
		return select_simd_target_op(selector, node, .SHA256MSG1)
	case .Sha256msg2:
		return select_simd_target_op(selector, node, .SHA256MSG2)
	case .Sha256rnds2:
		return select_simd_target_op(selector, node, .SHA256RNDS2)
	}
	return select_failure(selector)
}

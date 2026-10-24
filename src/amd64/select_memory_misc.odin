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
	case .Rcpss:
		return select_scalar_float_target_op(selector, node, .RCPSS)
	case .Rsqrtss:
		return select_scalar_float_target_op(selector, node, .RSQRTSS)
	case .Prefetch_T0:
		return select_prefetch(selector, node, .PREFETCHT0)
	case .Prefetch_T1:
		return select_prefetch(selector, node, .PREFETCHT1)
	case .Prefetch_T2:
		return select_prefetch(selector, node, .PREFETCHT2)
	case .Prefetch_Nta:
		return select_prefetch(selector, node, .PREFETCHNTA)
	case .Frame_Pointer:
		return select_frame_register(selector, node, Frame_Object{.Incoming, 0}, -16)
	case .Stack_Pointer:
		return select_frame_register(selector, node, Frame_Object{.Outgoing, 0}, 0)
	case .Stack_Restore:
		inputs := ir.node_inputs(selector.input, node)
		pointer := select_value(selector, inputs[2]) or_return
		return emit(selector.output, selector.block, .MOV, 8, Physical_Register(Gpr.RSP), pointer)
	case .Thread_Pointer:
		result := new_vreg(selector.output, .Int) or_return
		emit(selector.output, selector.block, .MOV, 8, result, Memory_Ref{segment_fs = true}) or_return
		selector.tuples[node] = make([]Vreg, 1, selector.allocator) or_return
		selector.tuples[node][0] = result
		return nil
	case .C_Va_Start:
		return select_c_va_start(selector, node)
	case .Valgrind_Client_Request:
		return select_client_request(selector, node)
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

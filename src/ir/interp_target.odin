package ir

import "core:math"

// `cpuid` leaf 0 reports maximum leaf 1 and the vendor string "OdinInte rp00" in ebx, edx, ecx;
// every other leaf reports zeros.
interp_cpuid :: proc(leaf: u32) -> [4]u64 {
	if leaf == 0 {
		return {1, 0x6E69644F, 0x30307072, 0x65746E49}
	}
	return {}
}

// Publishes each result on the `Proj` with index `k` holding result `k - 1`. `Xgetbv` 0 reports
// x87 and SSE enabled; `Rdtsc` counts one per execution, starting at 1.
interp_target_op :: proc(s: ^Interp_State, id: Node_Id) -> (ok: bool) {
	results: [4]u64
	#partial switch Target_Op(s.fn.nodes.data[id].index) {
	case .Debug_Trap:
		interp_fail(s, .Trap, id)
		return false
	case .Frame_Pointer, .Stack_Pointer, .Stack_Restore, .Thread_Pointer:
		interp_fail(s, .Unsupported, id)
		return false
	case .C_Va_Start:
		interp_fail(s, .Unsupported, id)
		return false
	case .Cpuid:
		leaf := interp_operand(s, id, 2) or_return
		results = interp_cpuid(u32(leaf))
	case .Xgetbv:
		register := interp_operand(s, id, 2) or_return
		if register == 0 {
			results[0] = 3
		}
	case .Rdtsc:
		s.machine.time_stamp_counter += 1
		results[0] = s.machine.time_stamp_counter
	case .Rcpss:
		results[0] = interp_f32_bits(1 / transmute(f32)u32(interp_operand(s, id, 2) or_return))
	case .Rsqrtss:
		results[0] = interp_f32_bits(1 / math.sqrt(transmute(f32)u32(interp_operand(s, id, 2) or_return)))
	case .Valgrind_Client_Request:
		results[0] = interp_operand(s, id, 2) or_return
	}
	for use in uses_of(s.uses, id) {
		index := s.fn.nodes.data[use.user].index
		if s.fn.nodes.kind[use.user] == .Proj && use.slot == 0 && index >= 1 {
			s.values[use.user] = results[index - 1]
			s.stamps[use.user] = s.generation
		}
	}
	return true
}

package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"

// A 128-bit operand is the address of a `#simd[16]u8`; it is loaded as one `V128` value. The result is stored
// into a new slot, so the `#simd` value stays an address.
@(private)
lower_simd_target_op :: proc(
	state: ^Procedure_State,
	node: syntax.Node_Index,
	info: check.Expression_Info,
	plan: check.Builtin_Plan,
	kind: check.Builtin_Kind,
) -> ir.Node_Id {
	operation: ir.Target_Op
	#partial switch kind {
	case .X86_Aesenc:
		operation = .Aesenc
	case .X86_Aesenclast:
		operation = .Aesenclast
	case .X86_Aesimc:
		operation = .Aesimc
	case .X86_Aeskeygenassist:
		operation = .Aeskeygenassist
	case .X86_Aesdec:
		operation = .Aesdec
	case .X86_Aesdeclast:
		operation = .Aesdeclast
	case .X86_Pclmulqdq:
		operation = .Pclmulqdq
	case .X86_Sha256msg1:
		operation = .Sha256msg1
	case .X86_Sha256msg2:
		operation = .Sha256msg2
	case .X86_Sha256rnds2:
		operation = .Sha256rnds2
	case:
		return lower_fail(state, node, .Builtin)
	}
	storage: [4]ir.Node_Id
	values, ok := lower_intrinsic_operands(state, node, plan, storage[:])
	if !ok { return 0 }
	count := len(plan.arguments)
	if count != int(ir.target_op_info[operation].arg_count) { return lower_fail(state, node, .Builtin) }
	arguments: [3]ir.Node_Id
	for index in 0 ..< count {
		is_immediate := kind == .X86_Aeskeygenassist && index == 1 || kind == .X86_Pclmulqdq && index == 2
		arguments[index] = values[index] if is_immediate else lower_load_word(state, values[index], .V128)
	}
	results: [1]ir.Node_Id
	if !lower_target_op(state, node, operation, arguments[:count], results[:]) { return 0 }
	copy := simd_slot(state, info.type)
	lower_store_word(state, copy, results[0])
	return copy
}

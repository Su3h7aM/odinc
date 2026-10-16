package lower

import "base:runtime"
import "core:math/big"
import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:types"

@(private)
lower_constant :: proc(state: ^Procedure_State, id: check.Const_Id, target: types.Type_Id) -> ir.Node_Id {
	constant := check.constant(state.job.program, id)
	assert(constant != nil)
	type := target if target != 0 else constant.type
	scalar := scalar_type(state, type)
	if scalar == .None { return lower_fail(state, state.job.procedure.body.node, .Constant) }
	function := state.job.function
	#partial switch value in constant.value {
	case bool:
		return ir.const_int(function, .Bool, i64(value))
	case big.Int:
		if scalar < .I8 || scalar > .I64 { return lower_fail(state, state.job.procedure.body.node, .Constant) }
		integer := value
		allocator := virtual.arena_allocator(&function.arena)
		if signed_type(state, type) {
			bits, error := big.int_get_i64(&integer, allocator)
			if error != .None { return lower_constant_error(state, error) }
			return ir.const_int(function, scalar, bits)
		}
		bits, error := big.int_get_u64(&integer, allocator)
		if error != .None { return lower_constant_error(state, error) }
		return ir.const_int(function, scalar, i64(bits))
	case check.Float_Value:
		if scalar < .F16 || scalar > .F64 || scalar_bits(scalar) != int(value.width) {
			return lower_fail(state, state.job.procedure.body.node, .Constant)
		}
		return ir.const_float(function, scalar, value.bits)
	case check.Pointer_Value:
		return ir.const_int(function, .Ptr, i64(value))
	case check.Nil_Value:
		return ir.const_int(function, scalar, 0)
	case check.Uninitialized_Value:
		return ir.undef(function, scalar)
	case check.Address_Value:
		assert(int(value.symbol) > 0 && int(value.symbol) < len(state.job.symbols))
		return ir.ptr_offset(function, ir.symbol_addr(function, state.job.symbols[value.symbol]), value.addend)
	case:
		return lower_fail(state, state.job.procedure.body.node, .Constant)
	}
}

@(private)
lower_constant_error :: proc(state: ^Procedure_State, error: big.Error) -> ir.Node_Id {
	if error >= .Out_Of_Memory && error <= .Mode_Not_Implemented {
		state.job.function.error = runtime.Allocator_Error(error)
		return 0
	}
	assert(false, "invalid checked scalar constant")
	return 0
}

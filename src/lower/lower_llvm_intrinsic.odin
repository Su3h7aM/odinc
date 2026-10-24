package lower

import "core:strings"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// Foreign procedures named `llvm.*` are the official backend's LLVM intrinsics. They have no symbol to link
// against, so each supported one is lowered to IR where the call stands.
@(private)
llvm_intrinsic_name :: proc(state: ^Procedure_State, plan: check.Call_Plan) -> (name: string, is_intrinsic: bool) {
	program := state.job.program
	if plan.entity == 0 || int(plan.entity) >= len(program.entities) { return "", false }
	entity := program.entities[plan.entity]
	if entity.kind != .Procedure || .Foreign not_in entity.flags { return "", false }
	return entity.link_name, strings.has_prefix(entity.link_name, "llvm.")
}

// `arguments` are the call's ABI values in parameter order.
@(private)
lower_llvm_intrinsic :: proc(state: ^Procedure_State, node: syntax.Node_Index, name: string, result: types.Type_Id, arguments: []ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	switch name {
	case "llvm.fmuladd.f16", "llvm.fmuladd.f32", "llvm.fmuladd.f64":
		if len(arguments) != 3 { return lower_fail(state, node, .Builtin) }
		if is_float16(state, result) {
			product, _ := lower_float16_operation(function, .Mul, arguments[0], arguments[1])
			sum, _ := lower_float16_operation(function, .Add, product, arguments[2])
			return sum
		}
		type := function.nodes.type[arguments[0]]
		if !is_float_type(type) || function.nodes.type[arguments[1]] != type || function.nodes.type[arguments[2]] != type {
			return lower_fail(state, node, .Builtin)
		}
		return ir.binary(function, .FAdd, ir.binary(function, .FMul, arguments[0], arguments[1]), arguments[2])
	case "llvm.returnaddress", "llvm.returnaddress.p0":
		return lower_frame_query(state, node, .Return_Address, arguments)
	case "llvm.frameaddress.p0":
		return lower_frame_query(state, node, .Frame_Address, arguments)
	case "llvm.addressofreturnaddress.p0":
		return lower_frame_query(state, node, .Address_Of_Return_Address, arguments)
	case "llvm.stacksave.p0":
		return lower_frame_query(state, node, .Stack_Pointer, arguments)
	case "llvm.stackrestore.p0":
		lower_target_op(state, node, .Stack_Restore, arguments, nil)
		return 0
	case "llvm.readcyclecounter":
		counter: [1]ir.Node_Id
		lower_target_op(state, node, .Rdtsc, arguments, counter[:])
		return counter[0]
	case "llvm.thread.pointer", "llvm.thread.pointer.p0":
		thread_pointer: [1]ir.Node_Id
		lower_target_op(state, node, .Thread_Pointer, arguments, thread_pointer[:])
		return thread_pointer[0]
	case "llvm.prefetch.p0":
		// Operands: address, read or write, locality, data or instruction cache; an instruction prefetch has no effect to emit.
		if len(arguments) != 4 || function.nodes.kind[arguments[3]] != .Const_Int { return lower_fail(state, node, .Builtin) }
		if function.nodes.data[arguments[3]].int_value == 0 { return 0 }
		return lower_data_prefetch(state, node, {arguments[0], arguments[2]})
	case "llvm.memcpy.p0.p0.i32",
	     "llvm.memcpy.p0.p0.i64",
	     "llvm.memcpy.inline.p0.p0.i32",
	     "llvm.memcpy.inline.p0.p0.i64",
	     "llvm.memmove.p0.p0.i32",
	     "llvm.memmove.p0.p0.i64":
		if len(arguments) != 4 ||
		   function.nodes.type[arguments[0]] != .Ptr ||
		   function.nodes.type[arguments[1]] != .Ptr { return lower_fail(state, node, .Builtin) }
		return lower_memory_effect(state, .Mem_Copy, arguments[0], arguments[1], widen_byte_count(function, arguments[2]))
	case "llvm.memset.p0.i32", "llvm.memset.p0.i64", "llvm.memset.inline.p0.i32", "llvm.memset.inline.p0.i64":
		if len(arguments) != 4 || function.nodes.type[arguments[0]] != .Ptr { return lower_fail(state, node, .Builtin) }
		return lower_memory_effect(state, .Mem_Set, arguments[0], arguments[1], widen_byte_count(function, arguments[2]))
	}
	return lower_llvm_family(state, node, name, result, arguments)
}

@(private)
widen_byte_count :: proc(function: ^ir.Function, count: ir.Node_Id) -> ir.Node_Id {
	if function.nodes.type[count] == .I64 { return count }
	return ir.convert(function, .Zext, count, .I64)
}

// `llvm.copysign`: magnitude of `magnitude`, sign bit of `sign`.
@(private)
llvm_copysign :: proc(function: ^ir.Function, magnitude, sign: ir.Node_Id) -> ir.Node_Id {
	type := function.nodes.type[magnitude]
	bits_type := type if type == .I16 else float_bits_type(type)
	magnitude_mask := i64(0x7fff) if type == .I16 else float_magnitude_mask(bits_type)
	magnitude_bits, sign_bits := magnitude, sign
	if type != .I16 {
		magnitude_bits = ir.convert(function, .Bitcast, magnitude, bits_type)
		sign_bits = ir.convert(function, .Bitcast, sign, bits_type)
	}
	kept := ir.binary(function, .And, magnitude_bits, ir.const_int(function, bits_type, magnitude_mask))
	taken := ir.binary(function, .And, sign_bits, ir.const_int(function, bits_type, ~magnitude_mask))
	combined := ir.binary(function, .Or, kept, taken)
	if type == .I16 { return combined }
	return ir.convert(function, .Bitcast, combined, type)
}

// `llvm.fshl` / `llvm.fshr` on `bits`-wide integers: the double-width concatenation `high:low` shifted by `amount` modulo `bits`.
@(private)
llvm_funnel_shift :: proc(function: ^ir.Function, left: bool, bits: i64, high, low, amount: ir.Node_Id) -> ir.Node_Id {
	type := function.nodes.type[high]
	shift := ir.binary(function, .And, amount, ir.const_int(function, type, bits - 1))
	complement := ir.binary(function, .Sub, ir.const_int(function, type, bits), shift)
	shifted_in, shifted_out := high, low
	if !left { shifted_in, shifted_out = low, high }
	first := ir.binary(function, .Shl if left else .Shr, shifted_in, shift)
	second := ir.binary(function, .Shr if left else .Shl, shifted_out, complement)
	combined := ir.binary(function, .Or, first, second)
	passthrough := high if left else low
	return ir.select(function, ir.compare(function, .Eq, shift, ir.const_int(function, type, 0)), passthrough, combined)
}

// Intrinsics named `llvm.<operation>.<type>`; the 128-bit integer forms and the remaining libm-style operations have no lowering.
@(private)
lower_llvm_family :: proc(state: ^Procedure_State, node: syntax.Node_Index, name: string, result: types.Type_Id, arguments: []ir.Node_Id) -> ir.Node_Id {
	function := state.job.function
	last_dot := strings.last_index_byte(name, '.')
	operation, type_name := name[:last_dot], name[last_dot + 1:]
	if len(arguments) == 0 || type_name == "i128" { return lower_fail(state, node, .Builtin) }
	if rounds_to_integer(operation) { return lower_float_to_integer_rounding(state, node, operation, result, arguments[0]) }
	value := arguments[0]
	type := function.nodes.type[value]
	switch operation {
	case "llvm.bswap", "llvm.ctpop", "llvm.ctlz", "llvm.cttz", "llvm.bitreverse":
		if !is_integer_type(type) { return lower_fail(state, node, .Builtin) }
		kind := check.Builtin_Kind.Reverse_Bits
		switch operation {
		case "llvm.bswap":
			kind = .Byte_Swap
		case "llvm.ctpop":
			kind = .Count_Ones
		case "llvm.ctlz":
			kind = .Count_Leading_Zeros
		case "llvm.cttz":
			kind = .Count_Trailing_Zeros
		}
		return lower_bit_intrinsic(state, kind, value)
	case "llvm.copysign":
		if len(arguments) != 2 || function.nodes.type[arguments[1]] != type { return lower_fail(state, node, .Builtin) }
		return llvm_copysign(function, value, arguments[1])
	case "llvm.minnum", "llvm.maxnum", "llvm.minimum", "llvm.maximum", "llvm.minimumnum", "llvm.maximumnum":
		if len(arguments) != 2 { return lower_fail(state, node, .Builtin) }
		extremum, ok := llvm_float_extremum(function, operation, value, arguments[1])
		if !ok { return lower_fail(state, node, .Builtin) }
		return extremum
	case "llvm.round":
		rounded, ok := llvm_float_rounding(function, .Round, value)
		if !ok { return lower_fail(state, node, .Builtin) }
		return rounded
	case "llvm.fshl", "llvm.fshr":
		bits := integer_bit_width(type)
		if len(arguments) != 3 || bits == 0 || function.nodes.type[arguments[1]] != type || function.nodes.type[arguments[2]] != type {
			return lower_fail(state, node, .Builtin)
		}
		return llvm_funnel_shift(function, operation == "llvm.fshl", bits, value, arguments[1], arguments[2])
	case "llvm.fabs":
		return(
			ir.binary(function, .And, value, ir.const_int(function, .I16, 0x7fff)) if is_float16(state, result) else simd_float_sign_operation(function, .Simd_Abs, value) \
		)
	case "llvm.sqrt":
		if is_float16(state, result) { return float16_from_f32(function, ir.unary(function, .FSqrt, float16_widen(function, value))) }
		if !is_float_type(type) { return lower_fail(state, node, .Builtin) }
		return ir.unary(function, .FSqrt, value)
	case "llvm.ceil", "llvm.floor", "llvm.trunc", "llvm.nearbyint", "llvm.rint", "llvm.roundeven":
		kind := check.Builtin_Kind.Simd_Nearest
		switch operation {
		case "llvm.ceil":
			kind = .Simd_Ceil
		case "llvm.floor":
			kind = .Simd_Floor
		case "llvm.trunc":
			kind = .Simd_Trunc
		}
		if is_float16(state, result) { return float16_from_f32(function, simd_float_rounding_or_reciprocal(function, kind, float16_widen(function, value))) }
		if !is_float_type(type) { return lower_fail(state, node, .Builtin) }
		return simd_float_rounding_or_reciprocal(function, kind, value)
	}
	return lower_fail(state, node, .Builtin)
}

@(private)
integer_bit_width :: proc(type: ir.Value_Type) -> i64 {
	#partial switch type {
	case .I8:
		return 8
	case .I16:
		return 16
	case .I32:
		return 32
	case .I64:
		return 64
	}
	return 0
}

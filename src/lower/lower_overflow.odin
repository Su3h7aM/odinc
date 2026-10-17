package lower

import "oc:check"
import "oc:ir"

// The wrapped result and the overflow flag of `overflow_add`, `overflow_sub` or `overflow_mul`.
@(private)
lower_overflow :: proc(state: ^Procedure_State, kind: check.Builtin_Kind, signed: bool, left, right: ir.Node_Id) -> (value, overflow: ir.Node_Id) {
	function := state.job.function
	type := function.nodes.type[left]
	zero := ir.const_int(function, type, 0)
	#partial switch kind {
	case .Overflow_Add:
		value = ir.binary(function, .Add, left, right)
		if !signed { return value, ir.compare(function, .ULt, value, left) }
		differs := ir.binary(function, .And, ir.binary(function, .Xor, left, value), ir.binary(function, .Xor, right, value))
		return value, ir.compare(function, .SLt, differs, zero)
	case .Overflow_Sub:
		value = ir.binary(function, .Sub, left, right)
		if !signed { return value, ir.compare(function, .ULt, left, right) }
		differs := ir.binary(function, .And, ir.binary(function, .Xor, left, right), ir.binary(function, .Xor, left, value))
		return value, ir.compare(function, .SLt, differs, zero)
	case .Overflow_Mul:
		return lower_overflow_multiply(function, signed, left, right)
	}
	return 0, 0
}

// Narrow types multiply in 64 bits, where the product is exact, and overflow when it is not its own truncation.
@(private = "file")
lower_overflow_multiply :: proc(function: ^ir.Function, signed: bool, left, right: ir.Node_Id) -> (value, overflow: ir.Node_Id) {
	if function.nodes.type[left] == .I64 {
		value = ir.binary(function, .Mul, left, right)
		if signed {
			high := ir.binary(function, .Mul_Hi_S, left, right)
			return value, ir.compare(function, .Ne, high, ir.binary(function, .Sar, value, ir.const_int(function, .I64, 63)))
		}
		return value, ir.compare(function, .Ne, ir.binary(function, .Mul_Hi_U, left, right), ir.const_int(function, .I64, 0))
	}
	extend := ir.Node_Kind.Sext if signed else ir.Node_Kind.Zext
	product := ir.binary(function, .Mul, ir.convert(function, extend, left, .I64), ir.convert(function, extend, right, .I64))
	value = ir.convert(function, .Trunc, product, function.nodes.type[left])
	return value, ir.compare(function, .Ne, product, ir.convert(function, extend, value, .I64))
}

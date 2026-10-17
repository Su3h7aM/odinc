package amd64

import x86 "core:rexcode/isa/x86"
import "oc:ir"

@(private)
float_scalar :: proc(type: ir.Value_Type) -> (width: u8, ok: bool) {
	#partial switch type {
	case .F32:
		return 4, true
	case .F64:
		return 8, true
	}
	return 0, false
}

@(private)
float_move :: proc(type: ir.Value_Type) -> (mnemonic: x86.Mnemonic, width: u8, ok: bool) {
	#partial switch type {
	case .F32:
		return .MOVSS, 4, true
	case .F64:
		return .MOVSD, 8, true
	}
	return {}, 0, false
}

// Moves the low 4 or 8 bytes between a general register and an xmm register.
@(private)
float_gpr_transfer :: proc(type: ir.Value_Type) -> (mnemonic: x86.Mnemonic, width: u8) {
	if type == .F32 {
		return .MOVD, 4
	}
	return .MOVQ, 8
}

@(private)
scalar_arithmetic :: proc(type: ir.Value_Type, kind: ir.Node_Kind) -> (mnemonic: x86.Mnemonic, ok: bool) {
	if type == .F32 {
		#partial switch kind {
		case .FAdd:
			return .ADDSS, true
		case .FSub:
			return .SUBSS, true
		case .FMul:
			return .MULSS, true
		case .FDiv:
			return .DIVSS, true
		case:
			return {}, false
		}
	}
	#partial switch kind {
	case .FAdd:
		return .ADDSD, true
	case .FSub:
		return .SUBSD, true
	case .FMul:
		return .MULSD, true
	case .FDiv:
		return .DIVSD, true
	case:
		return {}, false
	}
}

@(private)
select_scalar :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input := selector.input
	kind := input.nodes.kind[node]
	type := input.nodes.type[node]
	source := ir.NODE_NONE
	if kind == .Bitcast {
		source = ir.node_input(input, node, 0)
	} else if kind == .Select {
		source = ir.node_input(input, node, 1)
	}
	source_type := input.nodes.type[source] if source != ir.NODE_NONE else .None
	if type == .F32 || type == .F64 || source_type == .F32 || source_type == .F64 {
		return select_float(selector, node)
	}
	return select_integer(selector, node)
}

// Materializes `bits` in `destination` through a general-register immediate.
@(private)
select_float_bits :: proc(selector: ^Selector, destination: Vreg, type: ir.Value_Type, bits: u64) -> Select_Status {
	if type != .F32 && type != .F64 {
		return select_failure(selector)
	}
	integer := new_vreg(selector.output, .Int) or_return
	transfer, width := float_gpr_transfer(type)
	if type == .F32 {
		emit(selector.output, selector.block, .MOV, 4, integer, Immediate(i64(i32(u32(bits))))) or_return
	} else {
		emit(selector.output, selector.block, .MOVABS, 8, integer, Immediate(i64(bits))) or_return
	}
	return emit(selector.output, selector.block, transfer, width, destination, integer)
}

@(private)
select_float :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input := selector.input
	kind := input.nodes.kind[node]
	type := input.nodes.type[node]
	inputs := ir.node_inputs(input, node)
	#partial switch kind {
	case .FAdd, .FSub, .FMul, .FDiv:
		width, ok := float_scalar(type)
		mnemonic, arithmetic_ok := scalar_arithmetic(type, kind)
		if !ok || !arithmetic_ok || len(inputs) != 2 {
			return select_failure(selector)
		}
		first := select_value(selector, inputs[0]) or_return
		second := select_value(selector, inputs[1]) or_return
		return emit(selector.output, selector.block, mnemonic, width, selector.values[node], first, second)
	case .FNeg:
		return select_float_neg(selector, node)
	case .FSqrt:
		width, ok := float_scalar(type)
		if !ok || len(inputs) != 1 {
			return select_failure(selector)
		}
		value := select_value(selector, inputs[0]) or_return
		return emit(selector.output, selector.block, .SQRTSS if type == .F32 else .SQRTSD, width, selector.values[node], value)
	case .FEq, .FNe, .FLt, .FLe:
		return select_float_compare(selector, node)
	case .Select:
		return select_float_select(selector, node)
	case .Bitcast:
		return select_float_bitcast(selector, node)
	case .Sint_To_Float, .Uint_To_Float:
		return select_integer_to_float(selector, node)
	case .Float_To_Sint, .Float_To_Uint:
		return select_float_to_integer(selector, node)
	case .Float_Ext, .Float_Trunc:
		return select_float_resize(selector, node)
	}
	return select_failure(selector)
}

@(private)
select_float_neg :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input := selector.input
	type := input.nodes.type[node]
	if _, ok := float_scalar(type); !ok {
		return select_failure(selector)
	}
	value := select_value(selector, ir.node_input(input, node, 0)) or_return
	sign: u64 = 0x8000_0000 if type == .F32 else 0x8000_0000_0000_0000
	mask := new_vreg(selector.output, .Float) or_return
	select_float_bits(selector, mask, type, sign) or_return
	return emit(selector.output, selector.block, .XORPS, 16, selector.values[node], value, mask)
}

// `FEq` is ordered (NaN compares false). `FNe` is true when unordered.
@(private)
select_float_compare :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	kind := input.nodes.kind[node]
	inputs := ir.node_inputs(input, node)
	operand_type := input.nodes.type[inputs[0]]
	width, ok := float_scalar(operand_type)
	if !ok || input.nodes.type[inputs[1]] != operand_type {
		return select_failure(selector)
	}
	first := select_value(selector, inputs[0]) or_return
	second := select_value(selector, inputs[1]) or_return
	compare: x86.Mnemonic = .UCOMISS if operand_type == .F32 else .UCOMISD
	destination := selector.values[node]
	if kind == .FEq || kind == .FNe {
		emit(output, selector.block, compare, width, first, second) or_return
		left := new_vreg(output, .Int) or_return
		right := new_vreg(output, .Int) or_return
		combined := new_vreg(output, .Int) or_return
		emit(output, selector.block, .SETE if kind == .FEq else .SETNE, 1, left) or_return
		emit(output, selector.block, .SETNP if kind == .FEq else .SETP, 1, right) or_return
		emit(output, selector.block, .AND if kind == .FEq else .OR, 1, combined, left, right) or_return
		return emit(output, selector.block, .MOVZX, 1, destination, combined)
	}
	// `ucomis second, first` then above/above-or-equal: NaN sets CF, so both are false.
	emit(output, selector.block, compare, width, second, first) or_return
	flag := new_vreg(output, .Int) or_return
	emit(output, selector.block, .SETA if kind == .FLt else .SETAE, 1, flag) or_return
	return emit(output, selector.block, .MOVZX, 1, destination, flag)
}

@(private)
select_float_select :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	type := input.nodes.type[node]
	transfer, width := float_gpr_transfer(type)
	if _, ok := float_scalar(type); !ok {
		return select_failure(selector)
	}
	inputs := ir.node_inputs(input, node)
	condition := select_value(selector, inputs[0]) or_return
	if_true := select_value(selector, inputs[1]) or_return
	if_false := select_value(selector, inputs[2]) or_return
	true_bits := new_vreg(output, .Int) or_return
	false_bits := new_vreg(output, .Int) or_return
	chosen := new_vreg(output, .Int) or_return
	emit(output, selector.block, transfer, width, true_bits, if_true) or_return
	emit(output, selector.block, transfer, width, false_bits, if_false) or_return
	emit(output, selector.block, .TEST, 1, condition, condition) or_return
	emit(output, selector.block, .CMOVNE, width, chosen, false_bits, true_bits) or_return
	return emit(output, selector.block, transfer, width, selector.values[node], chosen)
}

@(private)
select_float_bitcast :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input := selector.input
	source := ir.node_input(input, node, 0)
	from := input.nodes.type[source]
	to := input.nodes.type[node]
	if select_width(from) != select_width(to) || select_width(to) != 4 && select_width(to) != 8 {
		return select_failure(selector, .Malformed_Input)
	}
	value := select_value(selector, source) or_return
	from_float := from == .F32 || from == .F64
	to_float := to == .F32 || to == .F64
	if from_float == to_float {
		return emit_pseudo(selector.output, selector.block, .Copy, selector.values[node], value)
	}
	transfer, width := float_gpr_transfer(to if to_float else from)
	return emit(selector.output, selector.block, transfer, width, selector.values[node], value)
}

@(private)
select_integer_to_float :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input := selector.input
	type := input.nodes.type[node]
	if _, ok := float_scalar(type); !ok {
		return select_failure(selector)
	}
	source := ir.node_input(input, node, 0)
	source_type := input.nodes.type[source]
	if select_width(source_type) == 0 {
		return select_failure(selector)
	}
	signed := input.nodes.kind[node] == .Sint_To_Float
	if !signed && source_type == .I64 {
		return select_uint64_to_float(selector, node)
	}
	integer := select_extended(selector, source, signed) or_return
	// Unsigned values are zero-extended and converted as signed 64-bit. Signed values
	// narrower than 64 bits use the 32-bit form, whose source has already been sign-extended.
	convert_width := u8(4) if signed && source_type != .I64 else 8
	mnemonic: x86.Mnemonic = .CVTSI2SS if type == .F32 else .CVTSI2SD
	return emit(selector.output, selector.block, mnemonic, convert_width, selector.values[node], integer)
}

// Branch-free unsigned 64-bit conversion: values with the high bit set are halved
// (preserving the low bit), converted, and doubled. The result matches IEEE rounding.
@(private)
select_uint64_to_float :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	type := input.nodes.type[node]
	source := select_value(selector, ir.node_input(input, node, 0)) or_return
	half := new_vreg(output, .Int) or_return
	low := new_vreg(output, .Int) or_return
	adjusted := new_vreg(output, .Int) or_return
	chosen := new_vreg(output, .Int) or_return
	emit(output, selector.block, .SHR, 8, half, source, Immediate(1)) or_return
	emit(output, selector.block, .AND, 8, low, source, Immediate(1)) or_return
	emit(output, selector.block, .OR, 8, adjusted, half, low) or_return
	emit(output, selector.block, .TEST, 8, source, source) or_return
	emit(output, selector.block, .CMOVNS, 8, chosen, adjusted, source) or_return

	converted := new_vreg(output, .Float) or_return
	doubled := new_vreg(output, .Float) or_return
	convert: x86.Mnemonic = .CVTSI2SS if type == .F32 else .CVTSI2SD
	add: x86.Mnemonic = .ADDSS if type == .F32 else .ADDSD
	emit(output, selector.block, convert, 8, converted, chosen) or_return
	emit(output, selector.block, add, float_scalar(type) or_else 0, doubled, converted, converted) or_return

	transfer, width := float_gpr_transfer(type)
	converted_bits := new_vreg(output, .Int) or_return
	doubled_bits := new_vreg(output, .Int) or_return
	chosen_bits := new_vreg(output, .Int) or_return
	emit(output, selector.block, transfer, width, converted_bits, converted) or_return
	emit(output, selector.block, transfer, width, doubled_bits, doubled) or_return
	emit(output, selector.block, .CMOVNS, width, chosen_bits, doubled_bits, converted_bits) or_return
	return emit(output, selector.block, transfer, width, selector.values[node], chosen_bits)
}

@(private)
select_float_to_integer :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input := selector.input
	type := input.nodes.type[node]
	source := ir.node_input(input, node, 0)
	source_type := input.nodes.type[source]
	if _, ok := float_scalar(source_type); !ok || select_width(type) == 0 {
		return select_failure(selector)
	}
	if input.nodes.kind[node] == .Float_To_Uint && type == .I64 {
		return select_float_to_uint64(selector, node)
	}
	value := select_value(selector, source) or_return
	mnemonic: x86.Mnemonic = .CVTTSS2SI if source_type == .F32 else .CVTTSD2SI
	// Narrow unsigned results fit in a signed 64-bit conversion. Out of range is undefined.
	width := u8(4) if input.nodes.kind[node] == .Float_To_Sint && type != .I64 else 8
	return emit(selector.output, selector.block, mnemonic, width, selector.values[node], value)
}

// Values at or above 2^63 are shifted into the signed range and the high bit is restored.
@(private)
select_float_to_uint64 :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input, output := selector.input, selector.output
	source_node := ir.node_input(input, node, 0)
	source_type := input.nodes.type[source_node]
	source := select_value(selector, source_node) or_return
	threshold_bits: u64 = 0x5f00_0000 if source_type == .F32 else 0x43e0_0000_0000_0000
	threshold := new_vreg(output, .Float) or_return
	select_float_bits(selector, threshold, source_type, threshold_bits) or_return
	compare: x86.Mnemonic = .UCOMISS if source_type == .F32 else .UCOMISD
	above := new_vreg(output, .Int) or_return
	emit(output, selector.block, compare, float_scalar(source_type) or_else 0, threshold, source) or_return
	emit(output, selector.block, .SETBE, 1, above) or_return

	transfer, width := float_gpr_transfer(source_type)
	zero := new_vreg(output, .Int) or_return
	mask := new_vreg(output, .Int) or_return
	bias_bits := new_vreg(output, .Int) or_return
	emit(output, selector.block, .MOV, 4, zero, Immediate(0)) or_return
	if source_type == .F32 {
		emit(output, selector.block, .MOV, 4, mask, Immediate(i64(i32(u32(threshold_bits))))) or_return
	} else {
		emit(output, selector.block, .MOVABS, 8, mask, Immediate(i64(threshold_bits))) or_return
	}
	emit(output, selector.block, .TEST, 1, above, above) or_return
	emit(output, selector.block, .CMOVNE, width, bias_bits, zero, mask) or_return
	bias := new_vreg(output, .Float) or_return
	adjusted := new_vreg(output, .Float) or_return
	emit(output, selector.block, transfer, width, bias, bias_bits) or_return
	subtract: x86.Mnemonic = .SUBSS if source_type == .F32 else .SUBSD
	emit(output, selector.block, subtract, float_scalar(source_type) or_else 0, adjusted, source, bias) or_return

	converted := new_vreg(output, .Int) or_return
	convert: x86.Mnemonic = .CVTTSS2SI if source_type == .F32 else .CVTTSD2SI
	emit(output, selector.block, convert, 8, converted, adjusted) or_return
	high := new_vreg(output, .Int) or_return
	shifted := new_vreg(output, .Int) or_return
	emit(output, selector.block, .MOVABS, 8, high, Immediate(transmute(i64)(u64(1) << 63))) or_return
	emit(output, selector.block, .ADD, 8, shifted, converted, high) or_return
	emit(output, selector.block, .TEST, 1, above, above) or_return
	return emit(output, selector.block, .CMOVNE, 8, selector.values[node], converted, shifted)
}

@(private)
select_float_resize :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input := selector.input
	source := ir.node_input(input, node, 0)
	from := input.nodes.type[source]
	to := input.nodes.type[node]
	value := select_value(selector, source) or_return
	mnemonic: x86.Mnemonic
	if from == .F32 && to == .F64 {
		mnemonic = .CVTSS2SD
	} else if from == .F64 && to == .F32 {
		mnemonic = .CVTSD2SS
	} else {
		return select_failure(selector)
	}
	return emit(selector.output, selector.block, mnemonic, select_width(to), selector.values[node], value)
}

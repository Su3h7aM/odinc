package lower

import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
lower_conversion :: proc(state: ^Procedure_State, plan: check.Conversion_Plan, node: syntax.Node_Index) -> ir.Node_Id {
	assert(plan.kind != .Invalid, "missing checked conversion kind")
	if plan.kind == .Box || plan.kind == .Union_Injection || len(plan.path) != 0 { return lower_fail(state, node, .Conversion) }
	source_id := operand_type(state, plan.source)
	if state.failed { return 0 }
	constant_target := types.Type_Id(0)
	if types.is_untyped(check.type_store(state.job.program), source_id) { constant_target = plan.target }
	value := lower_operand(state, plan.source, constant_target)
	if state.failed { return 0 }
	function := state.job.function
	source := function.nodes.type[value]
	target := scalar_type(state, plan.target)
	if source == target { return value }
	if target == .None { return lower_fail(state, node, .Conversion) }
	if plan.kind == .Transmute {
		return ir.convert(function, .Bitcast, value, target)
	}
	source_signed := signed_type(state, operand_type(state, plan.source))
	if source == .Ptr || target == .Ptr {
		if source != .I64 && source != .Ptr || target != .I64 && target != .Ptr { return lower_fail(state, node, .Conversion) }
		return ir.convert(function, .Bitcast, value, target)
	}
	source_bits := scalar_bits(source)
	target_bits := scalar_bits(target)
	if source >= .I8 && source <= .I64 && target >= .I8 && target <= .I64 {
		if source_bits > target_bits { return ir.convert(function, .Trunc, value, target) }
		kind := ir.Node_Kind.Sext if source_signed else ir.Node_Kind.Zext
		return ir.convert(function, kind, value, target)
	}
	if source == .F32 || source == .F64 {
		if target == .F32 || target == .F64 {
			return ir.convert(function, .Float_Ext if source_bits < target_bits else .Float_Trunc, value, target)
		}
		if target >= .I8 && target <= .I64 {
			return ir.convert(function, .Float_To_Sint if signed_type(state, plan.target) else .Float_To_Uint, value, target)
		}
	}
	if source >= .I8 && source <= .I64 && (target == .F32 || target == .F64) {
		return ir.convert(function, .Sint_To_Float if source_signed else .Uint_To_Float, value, target)
	}
	return lower_fail(state, node, .Conversion)
}

@(private)
scalar_bits :: proc(type: ir.Value_Type) -> int {
	#partial switch type {
	case .Bool:
		return 1
	case .I8:
		return 8
	case .I16, .F16:
		return 16
	case .I32, .F32:
		return 32
	case .I64, .F64, .Ptr:
		return 64
	case:
		return 0
	}
}

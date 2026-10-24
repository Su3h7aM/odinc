package lower

import "base:runtime"
import "core:math/big"
import "core:mem"
import "core:mem/virtual"
import "core:unicode/utf16"
import "oc:check"
import "oc:ir"
import "oc:types"

@(private)
lower_constant :: proc(state: ^Procedure_State, id: check.Const_Id, target: types.Type_Id) -> ir.Node_Id {
	constant := check.constant(state.job.program, id)
	assert(constant != nil)
	type := target if target != 0 else constant.type
	type = types.default_type_of_untyped(check.type_store(state.job.program), type)
	if text, is_string := constant.value.(string); is_string {
		#partial switch lower_type(state, type).kind {
		case .CString:
			return lower_cstring(state, text)
		case .CString16:
			return lower_cstring16(state, text)
		case .String16:
			return lower_string16(state, text)
		case .String:
			return lower_string(state, text)
		case .Slice:
			descriptor := lower_type(state, type)
			size, alignment, error := types.layout(check.type_store(state.job.program), descriptor.elem)
			if error != .None || size <= 0 { return lower_fail(state, state.job.procedure.body.node, .Constant) }
			return lower_string(state, text, i64(len(text)) / size, u32(alignment))
		case:
			return lower_fail(state, state.job.procedure.body.node, .Constant)
		}
	}
	if variant, is_variant := constant.value.(check.Variant_Value); is_variant {
		payload := check.constant(state.job.program, variant.value)
		if payload == nil { return lower_fail(state, state.job.procedure.body.node, .Constant) }
		value := lower_constant(state, variant.value, payload.type)
		if state.failed { return 0 }
		plan := check.Conversion_Plan {
			kind   = .Union_Injection,
			target = type,
		}
		return lower_union_injection(state, state.job.procedure.body.node, plan, payload.type, value)
	}
	if aggregate, is_aggregate := constant.value.(check.Aggregate_Value); is_aggregate {
		return lower_constant_aggregate(state, constant.type, aggregate)
	}
	if slice, is_slice := constant.value.(check.Slice_Value); is_slice {
		backing := check.constant(state.job.program, slice.backing)
		plan := lower_constant_aggregate_plan(state, backing.type, backing.value.(check.Aggregate_Value))
		if state.job.function.error != nil { return 0 }
		return lower_slice_literal(state, state.job.procedure.body.node, check.Slice_Literal_Plan{type = type, backing = plan})
	}
	scalar := scalar_type(state, type)
	if _, is_nil := constant.value.(check.Nil_Value); is_nil && scalar == .None { return lower_zeroed_aggregate(state, type) }
	if components, is_complex := constant.value.(check.Complex_Value); is_complex { return lower_component_constant(state, components[:], type) }
	if components, is_quaternion := constant.value.(check.Quaternion_Value); is_quaternion { return lower_component_constant(state, components[:], type) }
	if is_wide_integer(state, type) {
		if integer, is_integer := constant.value.(big.Int); is_integer { return lower_wide_constant(state, integer) }
	}
	if scalar == .None { return lower_fail(state, state.job.procedure.body.node, .Constant) }
	function := state.job.function
	#partial switch value in constant.value {
	case bool:
		return ir.const_int(function, .Bool, i64(value))
	case big.Int:
		integer := value
		allocator := virtual.arena_allocator(&function.arena)
		if is_float_type(scalar) || is_float16(state, type) {
			rational: big.Rat
			if error := big.rat_set_int(&rational, &integer, allocator); error != .None { return lower_constant_error(state, error) }
			return lower_rational_constant(state, rational, type, scalar)
		}
		if scalar < .I8 || scalar > .I64 { return lower_fail(state, state.job.procedure.body.node, .Constant) }
		if signed_type(state, type) {
			bits, error := big.int_get_i64(&integer, allocator)
			if error != .None {
				// An untyped constant past the signed range still fits an unsigned use; keep its low 64 bits.
				source := target if target != 0 else constant.type
				if !types.is_untyped(check.type_store(state.job.program), source) { return lower_constant_error(state, error) }
				unsigned, unsigned_error := big.int_get_u64(&integer, allocator)
				if unsigned_error != .None { return lower_constant_error(state, unsigned_error) }
				return ir.const_int(function, scalar, i64(unsigned))
			}
			return ir.const_int(function, scalar, bits)
		}
		bits, error := big.int_get_u64(&integer, allocator)
		if error != .None { return lower_constant_error(state, error) }
		return ir.const_int(function, scalar, i64(bits))
	case check.Float_Value:
		return lower_float_constant(state, value, type, scalar)
	case big.Rat:
		return lower_rational_constant(state, value, type, scalar)
	case check.Pointer_Value:
		return ir.const_int(function, .Ptr, i64(value))
	case types.Type_Id:
		return lower_runtime_typeid(state, state.job.procedure.body.node, value)
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

// An untyped integer or rational is rounded once, directly to the target float precision.
@(private)
lower_rational_constant :: proc(state: ^Procedure_State, value: big.Rat, type: types.Type_Id, scalar: ir.Value_Type) -> ir.Node_Id {
	width: u8 = 64
	if is_float16(state, type) {
		width = 16
	} else if scalar == .F32 {
		width = 32
	} else if scalar != .F64 {
		return lower_fail(state, state.job.procedure.body.node, .Constant)
	}
	rational := value
	rounded, _, conversion_error := check.numeric_rational_to_f64(&rational, width)
	if conversion_error { return lower_fail(state, state.job.procedure.body.node, .Constant) }
	return lower_float_constant(state, check.Float_Value{bits = transmute(u64)rounded, width = 64}, type, scalar)
}

// A nil aggregate is all zero bytes, addressed like any other aggregate value.
@(private)
lower_zeroed_aggregate :: proc(state: ^Procedure_State, type: types.Type_Id) -> ir.Node_Id {
	layout := state.job.layouts[type]
	if layout.error != .None { return lower_fail(state, state.job.procedure.body.node, .Constant) }
	function := state.job.function
	slot := ir.stack_slot(function, state.entry_control, u32(layout.size), u32(layout.align))
	memory := ir.add_node(
		function,
		.Mem_Set,
		.Memory,
		{
			state.builder.control,
			ir.variable_get(state.builder, ir.MEMORY_VARIABLE),
			slot,
			ir.const_int(function, .I8, 0),
			ir.const_int(function, .I64, layout.size),
		},
	)
	ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	return slot
}

// A constant aggregate is copied from a read-only blob of this function into the storage a literal would use. An
// aggregate with no static image (an address, for one) is built like a literal, with one field store per element.
@(private)
lower_constant_aggregate :: proc(state: ^Procedure_State, type: types.Type_Id, aggregate: check.Aggregate_Value) -> ir.Node_Id {
	if state.failed || state.job.function.error != nil { return 0 }
	layout := state.job.layouts[type]
	if layout.error != .None || layout.size > i64(max(u32)) { return lower_fail(state, state.job.procedure.body.node, .Expression) }
	if image, found := lower_constant_blob(state, type, aggregate, layout); found {
		storage := aggregate_storage(state, layout)
		lower_store(state, storage, image, type)
		return storage
	}
	plan := lower_constant_aggregate_plan(state, type, aggregate)
	return lower_aggregate_struct_into(state, state.job.procedure.body.node, plan, aggregate_storage(state, layout), layout.size)
}

@(private)
lower_constant_blob :: proc(state: ^Procedure_State, type: types.Type_Id, aggregate: check.Aggregate_Value, layout: Type_Layout) -> (ir.Node_Id, bool) {
	function := state.job.function
	if layout.size <= 0 { return 0, false }
	allocator := virtual.arena_allocator(&function.arena)
	bytes, bytes_error := make([]byte, layout.size, allocator)
	if bytes_error != nil {
		function.error = bytes_error
		return 0, false
	}
	relocations := make([dynamic]ir.Data_Reloc, allocator)
	encoded, image_error := aggregate_constant_image(
		Image_Sink{function = function},
		state.job.program,
		type,
		aggregate.elements,
		bytes,
		0,
		&relocations,
		allocator,
	)
	if image_error != nil {
		function.error = image_error
		return 0, false
	}
	if !encoded { return 0, false }
	blob := ir.Symbol_Ref {
		space = .Local_Blob,
		index = u32(len(function.blobs)),
	}
	if _, append_error := append(&function.blobs, ir.Data_Blob{bytes = bytes, align = u32(layout.align), relocs = relocations[:]}); append_error != nil {
		function.error = append_error
		return 0, false
	}
	return ir.symbol_addr(function, blob), true
}

@(private)
lower_constant_aggregate_plan :: proc(state: ^Procedure_State, type: types.Type_Id, aggregate: check.Aggregate_Value) -> check.Aggregate_Plan {
	allocator := virtual.arena_allocator(&state.job.function.arena)
	values, values_error := make([]check.Operand, len(aggregate.elements), allocator)
	indices, indices_error := make([]u32, len(aggregate.elements), allocator)
	if values_error != nil || indices_error != nil {
		state.job.function.error = runtime.Allocator_Error.Out_Of_Memory
		return {}
	}
	for element, index in aggregate.elements {
		values[index] = check.Operand(element)
		indices[index] = u32(index)
	}
	return check.Aggregate_Plan{type = type, values = values, field_indices = indices}
}

@(private)
lower_float_constant :: proc(state: ^Procedure_State, value: check.Float_Value, type: types.Type_Id, scalar: ir.Value_Type) -> ir.Node_Id {
	function := state.job.function
	if is_float16(state, type) {
		bits, bits_ok := lower_float_bits(value, .F16)
		if !bits_ok { return lower_fail(state, state.job.procedure.body.node, .Constant) }
		return ir.const_int(function, .I16, i64(bits))
	}
	bits, bits_ok := lower_float_bits(value, scalar)
	if !bits_ok { return lower_fail(state, state.job.procedure.body.node, .Constant) }
	return ir.const_float(function, scalar, bits)
}

// Typed f32 values are stored with f64 bits. Narrow them when the target scalar is f32.
@(private)
lower_float_bits :: proc(value: check.Float_Value, scalar: ir.Value_Type) -> (bits: u64, ok: bool) {
	if scalar == .F64 && value.width == 64 { return value.bits, true }
	if scalar == .F32 {
		if value.width == 32 { return value.bits, true }
		if value.width == 64 { return u64(transmute(u32)f32(transmute(f64)value.bits)), true }
	}
	if scalar == .F16 && value.width == 16 { return value.bits, true }
	if scalar == .F16 && value.width == 64 { return u64(transmute(u16)f16(transmute(f64)value.bits)), true }
	return 0, false
}

// The bytes live in a blob of this function; the value is a header of data pointer and length, as for any string.
@(private)
lower_string :: proc(state: ^Procedure_State, text: string, count: i64 = -1, alignment: u32 = 1) -> ir.Node_Id {
	length := i64(len(text)) if count < 0 else count
	function := state.job.function
	address := ir.const_int(function, .I64, 0)
	if length != 0 {
		allocator := virtual.arena_allocator(&function.arena)
		bytes, bytes_error := make([]byte, len(text), allocator)
		if bytes_error != nil {
			function.error = bytes_error
			return 0
		}
		copy(bytes, text)
		blob := ir.Symbol_Ref {
			space = .Local_Blob,
			index = u32(len(function.blobs)),
		}
		if _, append_error := append(&function.blobs, ir.Data_Blob{bytes = bytes, align = alignment}); append_error != nil {
			function.error = append_error
			return 0
		}
		address = ir.symbol_addr(function, blob)
	}
	slot := ir.stack_slot(function, state.entry_control, 16, 8)
	lower_store_word(state, slot, address)
	lower_store_word(state, ir.ptr_offset(function, slot, 8), ir.const_int(function, .I64, length))
	return slot
}

@(private)
lower_cstring :: proc(state: ^Procedure_State, text: string) -> ir.Node_Id {
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	bytes, bytes_error := make([]byte, len(text) + 1, allocator)
	if bytes_error != nil { function.error = bytes_error; return 0 }
	copy(bytes, transmute([]byte)text)
	return lower_string_blob(state, bytes)
}

@(private)
lower_cstring16 :: proc(state: ^Procedure_State, text: string) -> ir.Node_Id {
	return lower_string16_data(state, text, true)
}

@(private)
lower_string16 :: proc(state: ^Procedure_State, text: string) -> ir.Node_Id {
	return lower_string16_data(state, text, false)
}

@(private)
lower_string16_data :: proc(state: ^Procedure_State, text: string, is_cstring: bool) -> ir.Node_Id {
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	units, units_error := make([]u16, len(text) + 1, allocator)
	if units_error != nil { function.error = units_error; return 0 }
	length := utf16.encode_string(units, text)
	byte_length := (length + 1) * size_of(u16)
	bytes, bytes_error := make([]byte, byte_length, allocator)
	if bytes_error != nil { function.error = bytes_error; return 0 }
	mem.copy(raw_data(bytes), raw_data(units), byte_length)
	address := ir.const_int(function, .I64, 0)
	if length != 0 || is_cstring {
		address = lower_string_blob(state, bytes)
	}
	if is_cstring { return address }
	slot := ir.stack_slot(function, state.entry_control, 16, 8)
	lower_store_word(state, slot, address)
	lower_store_word(state, ir.ptr_offset(function, slot, 8), ir.const_int(function, .I64, i64(length)))
	return slot
}

@(private)
lower_string_blob :: proc(state: ^Procedure_State, bytes: []byte) -> ir.Node_Id {
	function := state.job.function
	blob := ir.Symbol_Ref {
		space = .Local_Blob,
		index = u32(len(function.blobs)),
	}
	if _, append_error := append(&function.blobs, ir.Data_Blob{bytes = bytes, align = 1}); append_error != nil {
		function.error = append_error
		return 0
	}
	return ir.symbol_addr(function, blob)
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

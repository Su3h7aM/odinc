package ir

import "core:mem/virtual"

#assert(size_of(Node) == 24)

// Builder procedures take the function and share its sticky error: after a failed allocation
// they return `NODE_NONE`. Wrong operand kinds or types are programmer errors and assert;
// `verify` reports them as `Verify_Error`s on graphs built any other way.

Start_Nodes :: struct {
	control: Node_Id,
	memory:  Node_Id,
	params:  []Node_Id,
}

// Copies the parameter and result lists into the function arena.
add_signature :: proc(fn: ^Function, signature: Signature) -> Signature_Id {
	if fn.error != nil {
		return 0
	}
	allocator := virtual.arena_allocator(&fn.arena)
	stored := signature
	params, params_err := make([]Param, len(signature.params), allocator)
	results, results_err := make([]Result, len(signature.results), allocator)
	if params_err != nil || results_err != nil {
		fn.error = params_err if params_err != nil else results_err
		return 0
	}
	copy(params, signature.params)
	copy(results, signature.results)
	stored.params = params
	stored.results = results
	if _, err := append(&fn.signatures, stored); err != nil {
		fn.error = err
		return 0
	}
	return Signature_Id(len(fn.signatures) - 1)
}

// Creates `Start`, the entry head, the initial memory state and one projection per parameter
// of `fn.signature`, in that order.
start :: proc(fn: ^Function) -> Start_Nodes {
	assert(fn.start == NODE_NONE && int(fn.signature) < len(fn.signatures))
	signature := fn.signatures[fn.signature]
	params, params_err := make([]Node_Id, len(signature.params), virtual.arena_allocator(&fn.arena))
	if params_err != nil {
		fn.error = params_err
		return {}
	}
	fn.start = add_node(fn, .Start, .Tuple)
	nodes := Start_Nodes {
		control = add_node(fn, .Proj, .Control, {fn.start}, {index = 0}),
		memory  = add_node(fn, .Proj, .Memory, {fn.start}, {index = 1}),
		params  = params,
	}
	for param, index in signature.params {
		params[index] = add_node(fn, .Proj, param.type, {fn.start}, {index = u32(index + 2)})
	}
	return nodes
}

// Stored sign-extended from the width of `type` (`Bool` keeps bit 0).
const_int :: proc(fn: ^Function, type: Value_Type, value: i64) -> Node_Id {
	canonical: i64
	#partial switch type {
	case .Bool:
		canonical = value & 1
	case .I8:
		canonical = i64(i8(value))
	case .I16:
		canonical = i64(i16(value))
	case .I32:
		canonical = i64(i32(value))
	case:
		canonical = value
	}
	return interned_node(fn, .Const_Int, type, nil, {int_value = canonical}, {.Rematerialize})
}

const_float :: proc(fn: ^Function, type: Value_Type, bits: u64) -> Node_Id {
	return interned_node(fn, .Const_Float, type, nil, {float_bits = bits}, {.Rematerialize})
}

undef :: proc(fn: ^Function, type: Value_Type) -> Node_Id {
	return interned_node(fn, .Undef, type, nil, {}, {.Rematerialize})
}

symbol_addr :: proc(fn: ^Function, symbol: Symbol_Ref) -> Node_Id {
	return interned_node(fn, .Symbol_Addr, .Ptr, nil, {symbol = symbol}, {.Rematerialize})
}

tls_addr :: proc(fn: ^Function, symbol: Symbol_Ref) -> Node_Id {
	return interned_node(fn, .Tls_Addr, .Ptr, nil, {symbol = symbol}, {.Rematerialize})
}

// `entry` is the entry head from `start`.
stack_slot :: proc(fn: ^Function, entry: Node_Id, size, align: u32) -> Node_Id {
	return add_node(fn, .Stack_Slot, .Ptr, {entry}, {slot = {size = size, align = align}})
}

// Result type is the type of `a`: arithmetic, logic, shifts and `Mul_Hi_*`. Operands are
// ordered by id for commutative kinds.
binary :: proc(fn: ^Function, kind: Node_Kind, a, b: Node_Id) -> Node_Id {
	if fn.error != nil {
		return NODE_NONE
	}
	assert(is_pure(kind) && kind_info[kind].max_inputs == 2)
	a, b := a, b
	if .Commutative in kind_info[kind].flags && b < a {
		a, b = b, a
	}
	return interned_node(fn, kind, fn.nodes.type[a], {a, b}, {}, {})
}

// `Div` and `Rem` kinds are pinned to `control`.
divide :: proc(fn: ^Function, kind: Node_Kind, control, a, b: Node_Id) -> Node_Id {
	if fn.error != nil {
		return NODE_NONE
	}
	assert(kind == .SDiv || kind == .UDiv || kind == .SRem || kind == .URem)
	return add_node(fn, kind, fn.nodes.type[a], {control, a, b})
}

// `FNeg`, `FSqrt`, `Popcnt`, `Clz`, `Ctz` and `Bswap`.
unary :: proc(fn: ^Function, kind: Node_Kind, a: Node_Id) -> Node_Id {
	if fn.error != nil {
		return NODE_NONE
	}
	assert(is_pure(kind) && kind_info[kind].max_inputs == 1)
	return interned_node(fn, kind, fn.nodes.type[a], {a}, {}, {})
}

// Integer and float comparisons; `>` and `>=` are written by swapping operands.
compare :: proc(fn: ^Function, kind: Node_Kind, a, b: Node_Id) -> Node_Id {
	if fn.error != nil {
		return NODE_NONE
	}
	assert(kind_info[kind].result == {.Bool} && is_pure(kind))
	a, b := a, b
	if .Commutative in kind_info[kind].flags && b < a {
		a, b = b, a
	}
	return interned_node(fn, kind, .Bool, {a, b}, {}, {})
}

// `Trunc`, `Zext`, `Sext`, `Bitcast` and the int/float conversions.
convert :: proc(fn: ^Function, kind: Node_Kind, a: Node_Id, type: Value_Type) -> Node_Id {
	if fn.error != nil {
		return NODE_NONE
	}
	assert(is_pure(kind) && kind_info[kind].max_inputs == 1)
	return interned_node(fn, kind, type, {a}, {}, {})
}

select :: proc(fn: ^Function, condition, if_true, if_false: Node_Id) -> Node_Id {
	if fn.error != nil {
		return NODE_NONE
	}
	return interned_node(fn, .Select, fn.nodes.type[if_true], {condition, if_true, if_false}, {}, {})
}

ptr_offset :: proc(fn: ^Function, base: Node_Id, offset: i64) -> Node_Id {
	return interned_node(fn, .Ptr_Offset, .Ptr, {base}, {int_value = offset}, {})
}

ptr_index :: proc(fn: ^Function, base, index: Node_Id, stride: u32) -> Node_Id {
	return interned_node(fn, .Ptr_Index, .Ptr, {base, index}, {index = stride}, {})
}

load :: proc(fn: ^Function, control, memory, pointer: Node_Id, type: Value_Type, align_log2: u8) -> Node_Id {
	return add_node(fn, .Load, type, {control, memory, pointer}, {access = {align_log2 = align_log2}})
}

// Returns the new memory state.
store :: proc(fn: ^Function, control, memory, pointer, value: Node_Id, align_log2: u8) -> Node_Id {
	return add_node(fn, .Store, .Memory, {control, memory, pointer, value}, {access = {align_log2 = align_log2}})
}

// Returns the tuple `(memory, results…)`; read members with `Proj`.
call :: proc(fn: ^Function, control, memory, callee: Node_Id, signature: Signature_Id, args: []Node_Id) -> Node_Id {
	if fn.error != nil {
		return NODE_NONE
	}
	inputs_buf: [16]Node_Id
	if 3 + len(args) <= len(inputs_buf) {
		inputs_buf[0], inputs_buf[1], inputs_buf[2] = control, memory, callee
		copy(inputs_buf[3:], args)
		return add_node(fn, .Call, .Tuple, inputs_buf[:3 + len(args)], {index = u32(signature)})
	}
	inputs, err := make([]Node_Id, 3 + len(args), virtual.arena_allocator(&fn.arena))
	if err != nil {
		fn.error = err
		return NODE_NONE
	}
	inputs[0], inputs[1], inputs[2] = control, memory, callee
	copy(inputs[3:], args)
	return add_node(fn, .Call, .Tuple, inputs, {index = u32(signature)})
}

// Returns the projections `(true_head, false_head)`; each heads its own block.
if_ :: proc(fn: ^Function, control, condition: Node_Id) -> (true_head, false_head: Node_Id) {
	split := add_node(fn, .If, .Tuple, {control, condition})
	true_head = add_node(fn, .Proj, .Control, {split}, {index = 0})
	false_head = add_node(fn, .Proj, .Control, {split}, {index = 1})
	return
}

region :: proc(fn: ^Function, predecessors: []Node_Id) -> Node_Id {
	return add_node(fn, .Region, .Control, predecessors)
}

// One value per region input, in the same order; the type is the type of the first value.
phi :: proc(fn: ^Function, merge: Node_Id, values: []Node_Id) -> Node_Id {
	if fn.error != nil {
		return NODE_NONE
	}
	inputs_buf: [16]Node_Id
	if 1 + len(values) <= len(inputs_buf) {
		inputs_buf[0] = merge
		copy(inputs_buf[1:], values)
		return add_node(fn, .Phi, fn.nodes.type[values[0]], inputs_buf[:1 + len(values)])
	}
	inputs, err := make([]Node_Id, 1 + len(values), virtual.arena_allocator(&fn.arena))
	if err != nil {
		fn.error = err
		return NODE_NONE
	}
	inputs[0] = merge
	copy(inputs[1:], values)
	return add_node(fn, .Phi, fn.nodes.type[values[0]], inputs)
}

// `results` follow the signature's result pieces.
ret :: proc(fn: ^Function, control, memory: Node_Id, results: ..Node_Id) -> Node_Id {
	if fn.error != nil {
		return NODE_NONE
	}
	assert(len(results) <= 2)
	inputs: [4]Node_Id
	inputs[0], inputs[1] = control, memory
	copy(inputs[2:], results)
	return add_node(fn, .Return, .None, inputs[:2 + len(results)])
}

trap :: proc(fn: ^Function, control, memory: Node_Id) -> Node_Id {
	return add_node(fn, .Trap, .None, {control, memory})
}

unreachable :: proc(fn: ^Function, control, memory: Node_Id) -> Node_Id {
	return add_node(fn, .Unreachable, .None, {control, memory})
}

// Creates `Stop` over every terminator in id order and verifies the graph. Returns the sticky
// allocation error, else the code of the first verification error.
function_finish :: proc(fn: ^Function) -> Error {
	if fn.error != nil {
		return fn.error
	}
	assert(fn.stop == NODE_NONE)
	terminators := make([dynamic]Node_Id, fn.allocator)
	defer delete(terminators)
	for id in 1 ..< len(fn.nodes) {
		#partial switch fn.nodes.kind[id] {
		case .Return, .Unreachable, .Trap:
			if _, err := append(&terminators, Node_Id(id)); err != nil {
				return err
			}
		}
	}
	fn.stop = add_node(fn, .Stop, .None, terminators[:])
	if fn.error != nil {
		return fn.error
	}

	errors, err := verify(fn, fn.allocator)
	defer delete(errors, fn.allocator)
	if err != nil {
		return err
	}
	if len(errors) > 0 {
		return errors[0].code
	}
	return nil
}

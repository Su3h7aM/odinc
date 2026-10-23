package ir

import "base:runtime"
import "core:slice"

Verifier :: struct {
	fn:          ^Function,
	module:      ^Module,
	scratch:     runtime.Allocator,
	errors:      [dynamic]Verify_Error,
	failure:     runtime.Allocator_Error,
	entry:       Node_Id,
	// The initial memory state: `Proj 1` of `Start`.
	start_state: Node_Id,
	// The memory `Phi` of each `Region` and `Loop`, by node id.
	memory_phi:  []Node_Id,
	// Built once for the whole verification.
	uses:        Use_Table,
}

// Checks S1-S7 and C1-C3 of section 9. Edge rules run first; everything else is skipped while
// an edge is out of range, dangling or of the wrong arity, because the later rules read
// through edges. With `module` set, symbol indices are range-checked too. The caller frees the
// returned slice with `allocator`.
verify :: proc(fn: ^Function, allocator: runtime.Allocator, module: ^Module = nil) -> (errors: []Verify_Error, err: runtime.Allocator_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	v := Verifier {
		fn      = fn,
		module  = module,
		scratch = context.temp_allocator,
	}
	v.errors = make([dynamic]Verify_Error, allocator) or_return

	check_edges(&v)
	if len(v.errors) == 0 {
		check_anchors(&v)
		check_nodes(&v)
		uses, uses_err := uses_build(fn, v.scratch)
		if uses_err != nil {
			v.failure = uses_err
		} else {
			v.uses = uses
			check_projections(&v)
			check_control(&v)
		}
	}
	if v.failure != nil {
		delete(v.errors)
		return nil, v.failure
	}
	return v.errors[:], nil
}

report_error :: proc(v: ^Verifier, node, other: Node_Id, code: Verify_Code) {
	if _, err := append(&v.errors, Verify_Error{node = node, other = other, code = code}); err != nil {
		v.failure = err
	}
}

node_type :: proc(v: ^Verifier, id: Node_Id) -> Value_Type {
	return v.fn.nodes.type[id]
}

@(private = "file")
value_bits :: proc(type: Value_Type) -> int {
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
	case .V128:
		return 128
	}
	return 0
}

// S2, S3 (arity) and S7.
@(private = "file")
check_edges :: proc(v: ^Verifier) {
	fn := v.fn
	if fn.nodes.kind[0] != .Invalid {
		report_error(v, 0, NODE_NONE, .Invalid_Anchor)
	}
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		kind := fn.nodes.kind[id]
		count := int(fn.nodes.input_count[id])
		if kind == .Removed {
			if count != 0 {
				report_error(v, id, NODE_NONE, .Removed_Node_Linked)
			}
			continue
		}
		if kind == .Invalid {
			report_error(v, id, NODE_NONE, .Invalid_Anchor)
			continue
		}
		if int(fn.nodes.first_input[id]) + count > len(fn.edges) {
			report_error(v, id, NODE_NONE, .Bad_Arity)
			continue
		}
		info := &kind_info[kind]
		if count < int(info.min_inputs) || count > int(info.max_inputs) {
			report_error(v, id, NODE_NONE, .Bad_Arity)
		}
		for input in node_inputs(fn, id) {
			if input == NODE_NONE || int(input) >= len(fn.nodes) {
				report_error(v, id, input, .Bad_Input_Id)
			} else if fn.nodes.kind[input] == .Removed {
				report_error(v, id, input, .Removed_Node_Linked)
			}
		}
	}
}

// S1 and the function-level part of S6.
@(private = "file")
check_anchors :: proc(v: ^Verifier) {
	fn := v.fn
	start_count, stop_count := 0, 0
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		#partial switch fn.nodes.kind[id] {
		case .Start:
			start_count += 1
			if id != fn.start {
				report_error(v, id, fn.start, .Invalid_Anchor)
			}
		case .Stop:
			stop_count += 1
			if id != fn.stop {
				report_error(v, id, fn.stop, .Invalid_Anchor)
			}
		case .Proj:
			if node_input(fn, id, 0) == fn.start {
				if fn.nodes.type[id] == .Control && fn.nodes.data[id].index == 0 {
					v.entry = id
				} else if fn.nodes.type[id] == .Memory && fn.nodes.data[id].index == 1 {
					v.start_state = id
				}
			}
		}
	}
	if start_count != 1 || stop_count != 1 {
		report_error(v, fn.start, fn.stop, .Invalid_Anchor)
		return
	}
	if int(fn.signature) >= len(fn.signatures) {
		report_error(v, fn.start, NODE_NONE, .Bad_Node_Data)
	}
	for signature in fn.signatures {
		if len(signature.results) > 2 {
			report_error(v, fn.start, NODE_NONE, .Bad_Node_Data)
		}
	}

	is_stop_input := make([]bool, len(fn.nodes), v.scratch)
	for input in node_inputs(fn, fn.stop) {
		kind := fn.nodes.kind[input]
		if (kind != .Return && kind != .Unreachable && kind != .Trap) || is_stop_input[input] {
			report_error(v, fn.stop, input, .Invalid_Anchor)
		}
		is_stop_input[input] = true
	}
	for index in 1 ..< len(fn.nodes) {
		#partial switch fn.nodes.kind[index] {
		case .Return, .Unreachable, .Trap:
			if !is_stop_input[index] {
				report_error(v, fn.stop, Node_Id(index), .Invalid_Anchor)
			}
		}
	}
}

@(private = "file")
check_nodes :: proc(v: ^Verifier) {
	fn := v.fn
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		kind := fn.nodes.kind[id]
		if kind == .Removed {
			continue
		}
		if fn.nodes.type[id] not_in kind_info[kind].result {
			report_error(v, id, NODE_NONE, .Bad_Type)
		}
		for input, slot in node_inputs(fn, id) {
			if node_type(v, input) not_in input_types(kind, slot) {
				report_error(v, id, input, .Bad_Type)
			}
		}
		check_operand_relations(v, id)
		check_node_data(v, id)
	}
}

// S4 rules that depend on the types of several operands.
@(private = "file")
check_operand_relations :: proc(v: ^Verifier, id: Node_Id) {
	fn := v.fn
	inputs := node_inputs(fn, id)
	type := node_type(v, id)
	#partial switch fn.nodes.kind[id] {
	case .Add, .Sub, .Mul, .And, .Or, .Xor, .FAdd, .FSub, .FMul, .FDiv, .Mul_Hi_S, .Mul_Hi_U:
		if node_type(v, inputs[0]) != node_type(v, inputs[1]) || type != node_type(v, inputs[0]) {
			report_error(v, id, inputs[1], .Bad_Type)
		}
	case .SDiv, .UDiv, .SRem, .URem:
		if node_type(v, inputs[1]) != node_type(v, inputs[2]) || type != node_type(v, inputs[1]) {
			report_error(v, id, inputs[2], .Bad_Type)
		}
	case .Shl, .Shr, .Sar, .FNeg, .FSqrt, .Popcnt, .Clz, .Ctz, .Bswap:
		if type != node_type(v, inputs[0]) {
			report_error(v, id, inputs[0], .Bad_Type)
		}
	case .Eq, .Ne, .SLt, .SLe, .ULt, .ULe, .FEq, .FLt, .FLe, .FNe:
		if node_type(v, inputs[0]) != node_type(v, inputs[1]) {
			report_error(v, id, inputs[1], .Bad_Type)
		}
	case .Select:
		if node_type(v, inputs[1]) != node_type(v, inputs[2]) || type != node_type(v, inputs[1]) {
			report_error(v, id, inputs[2], .Bad_Type)
		}
	case .Trunc, .Float_Trunc:
		if value_bits(type) >= value_bits(node_type(v, inputs[0])) {
			report_error(v, id, inputs[0], .Bad_Type)
		}
	case .Zext, .Sext, .Float_Ext:
		if value_bits(type) <= value_bits(node_type(v, inputs[0])) {
			report_error(v, id, inputs[0], .Bad_Type)
		}
	case .Bitcast:
		source := node_type(v, inputs[0])
		pointer_pairs_with_i64 := (source == .Ptr && type != .I64) || (type == .Ptr && source != .I64)
		if value_bits(type) != value_bits(source) || pointer_pairs_with_i64 {
			report_error(v, id, inputs[0], .Bad_Type)
		}
	case .Phi:
		for value in inputs[1:] {
			if node_type(v, value) != type {
				report_error(v, id, value, .Bad_Type)
			}
		}
		merge := inputs[0]
		if fn.nodes.kind[merge] != .Region && fn.nodes.kind[merge] != .Loop {
			report_error(v, id, merge, .Bad_Phi)
		} else if len(inputs) != int(fn.nodes.input_count[merge]) + 1 {
			report_error(v, id, merge, .Bad_Arity)
		}
	case .Const_Int:
		value := fn.nodes.data[id].int_value
		in_range := true
		#partial switch type {
		case .Bool:
			in_range = value == 0 || value == 1
		case .I8:
			in_range = value == i64(i8(value))
		case .I16:
			in_range = value == i64(i16(value))
		case .I32:
			in_range = value == i64(i32(value))
		}
		if !in_range {
			report_error(v, id, NODE_NONE, .Bad_Type)
		}
	case .Const_Float:
		bits := fn.nodes.data[id].float_bits
		if value_bits(type) < 64 && bits >> uint(value_bits(type)) != 0 {
			report_error(v, id, NODE_NONE, .Bad_Type)
		}
	}
}

// S6: indices, signatures and slot shape.
@(private = "file")
check_node_data :: proc(v: ^Verifier, id: Node_Id) {
	fn := v.fn
	inputs := node_inputs(fn, id)
	data := fn.nodes.data[id]
	#partial switch fn.nodes.kind[id] {
	case .Stack_Slot:
		slot := data.slot
		if slot.size == 0 || slot.align == 0 || slot.align & (slot.align - 1) != 0 || inputs[0] != v.entry {
			report_error(v, id, inputs[0], .Bad_Node_Data)
		}
	case .Symbol_Addr:
		check_symbol(v, id, data.symbol, false)
	case .Tls_Addr:
		check_symbol(v, id, data.symbol, true)
	case .Switch:
		if int(data.index) >= len(fn.tables) {
			report_error(v, id, NODE_NONE, .Bad_Node_Data)
			return
		}
		sorted, err := slice.clone(fn.tables[data.index], v.scratch)
		if err != nil {
			v.failure = err
			return
		}
		slice.sort(sorted)
		for case_index in 1 ..< len(sorted) {
			if sorted[case_index] == sorted[case_index - 1] {
				report_error(v, id, NODE_NONE, .Bad_Node_Data)
				break
			}
		}
	case .Load_Ordered:
		if data.access.value_type not_in input_types(.Store, 3) {
			report_error(v, id, NODE_NONE, .Bad_Node_Data)
		}
	case .Call:
		if int(data.index) >= len(fn.signatures) {
			report_error(v, id, NODE_NONE, .Bad_Node_Data)
			return
		}
		params := fn.signatures[data.index].params
		if len(inputs) - 3 != len(params) {
			report_error(v, id, NODE_NONE, .Bad_Node_Data)
			return
		}
		for param, index in params {
			if node_type(v, inputs[3 + index]) != param.type {
				report_error(v, id, inputs[3 + index], .Bad_Node_Data)
			}
		}
	case .Return:
		if int(fn.signature) >= len(fn.signatures) {
			return
		}
		results := fn.signatures[fn.signature].results
		if len(inputs) - 2 != len(results) {
			report_error(v, id, NODE_NONE, .Bad_Node_Data)
			return
		}
		for result, index in results {
			if node_type(v, inputs[2 + index]) != result.type {
				report_error(v, id, inputs[2 + index], .Bad_Node_Data)
			}
		}
	case .Target_Op:
		if int(data.index) >= len(Target_Op) {
			report_error(v, id, NODE_NONE, .Bad_Node_Data)
			return
		}
		info := &target_op_info[Target_Op(data.index)]
		if len(inputs) - 2 != int(info.arg_count) {
			report_error(v, id, NODE_NONE, .Bad_Node_Data)
			return
		}
		for arg_type, index in info.args[:info.arg_count] {
			if node_type(v, inputs[2 + index]) != arg_type {
				report_error(v, id, inputs[2 + index], .Bad_Node_Data)
			}
		}
	}
}

@(private = "file")
check_symbol :: proc(v: ^Verifier, id: Node_Id, symbol: Symbol_Ref, thread_local: bool) {
	module := v.module
	valid := false
	switch symbol.space {
	case .None:
	case .Local_Blob:
		valid = !thread_local && int(symbol.index) < len(v.fn.blobs)
	case .Function:
		valid = !thread_local && (module == nil || int(symbol.index) < len(module.functions))
	case .Extern:
		valid = !thread_local && (module == nil || int(symbol.index) < len(module.externs))
	case .Global:
		valid = module == nil || (int(symbol.index) < len(module.globals) && module.globals[symbol.index].tls == thread_local)
	}
	if !valid {
		report_error(v, id, NODE_NONE, .Bad_Node_Data)
	}
}

// What `Proj` reads from a tuple.
@(private = "file")
tuple_member :: proc(v: ^Verifier, tuple: Node_Id, index: int) -> (type: Value_Type, found: bool) {
	fn := v.fn
	data := fn.nodes.data[tuple]
	#partial switch fn.nodes.kind[tuple] {
	case .Start:
		if int(fn.signature) >= len(fn.signatures) {
			return
		}
		params := fn.signatures[fn.signature].params
		switch {
		case index == 0:
			return .Control, true
		case index == 1:
			return .Memory, true
		case index - 2 < len(params):
			return params[index - 2].type, true
		}
	case .If:
		return .Control, index < 2
	case .Switch:
		return .Control, int(data.index) < len(fn.tables) && index <= len(fn.tables[data.index])
	case .Load_Ordered:
		if index < 2 {
			return .Memory if index == 0 else data.access.value_type, true
		}
	case .Atomic_Rmw:
		if index < 2 {
			return .Memory if index == 0 else node_type(v, node_input(fn, tuple, 3)), true
		}
	case .Atomic_Cas:
		switch index {
		case 0:
			return .Memory, true
		case 1:
			return node_type(v, node_input(fn, tuple, 3)), true
		case 2:
			return .Bool, true
		}
	case .Call:
		if int(data.index) >= len(fn.signatures) {
			return
		}
		results := fn.signatures[data.index].results
		if index == 0 {
			return .Memory, true
		} else if index - 1 < len(results) {
			return results[index - 1].type, true
		}
	case .Syscall:
		if index < 2 {
			return .Memory if index == 0 else .I64, true
		}
	case .Target_Op:
		if int(data.index) >= len(Target_Op) {
			return
		}
		info := &target_op_info[Target_Op(data.index)]
		if index == 0 {
			return .Memory, true
		} else if index - 1 < int(info.result_count) {
			return info.results[index - 1], true
		}
	}
	return
}

// S5. Every `If` and `Switch` must have each projection exactly once.
@(private = "file")
check_projections :: proc(v: ^Verifier) {
	fn := v.fn
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		if fn.nodes.kind[id] != .Proj {
			continue
		}
		tuple := node_input(fn, id, 0)
		member, found := tuple_member(v, tuple, int(fn.nodes.data[id].index))
		if !found || node_type(v, id) != member {
			report_error(v, id, tuple, .Bad_Projection)
		}
	}

	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		if fn.nodes.kind[id] != .If && fn.nodes.kind[id] != .Switch {
			continue
		}
		member_count := 2
		if fn.nodes.kind[id] == .Switch {
			if int(fn.nodes.data[id].index) >= len(fn.tables) {
				continue
			}
			member_count = len(fn.tables[fn.nodes.data[id].index]) + 1
		}
		seen := make([]bool, member_count, v.scratch)
		for use in uses_of(v.uses, id) {
			if fn.nodes.kind[use.user] != .Proj {
				continue
			}
			member := int(fn.nodes.data[use.user].index)
			if member >= member_count {
				continue
			}
			if seen[member] {
				report_error(v, id, use.user, .Bad_Projection)
			}
			seen[member] = true
		}
		if slice.contains(seen, false) {
			report_error(v, id, NODE_NONE, .Bad_Projection)
		}
	}
}

// C1-C3.
@(private = "file")
check_control :: proc(v: ^Verifier) {
	fn := v.fn
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		kind := fn.nodes.kind[id]
		if kind == .Region || kind == .Loop {
			for input in node_inputs(fn, id) {
				if !is_block_head(fn, input) {
					report_error(v, id, input, .Control_Not_Head)
				}
			}
		} else if is_pinned(kind) && !is_block_head(fn, node_input(fn, id, 0)) {
			report_error(v, id, node_input(fn, id, 0), .Control_Not_Head)
		}
	}

	// Built into the temp allocator and freed by the guard in `verify`.
	cfg, err := build_control_skeleton(fn, v.scratch, v.uses, v.scratch)
	if err != nil {
		v.failure = err
		return
	}
	for exit_count, block in cfg.exit_counts {
		if exit_count != 1 {
			report_error(v, cfg.heads[block], NODE_NONE, .Head_Exit_Count)
		}
	}
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		if is_block_head(fn, id) && (int(id) >= len(cfg.block_of) || cfg.block_of[id] == BLOCK_NONE) {
			report_error(v, id, NODE_NONE, .Unreachable_Head)
		}
	}

	check_loops(v, cfg)
	check_phis(v)
	check_control_classes(v)
	check_placement(v, cfg)
	check_memory(v, cfg)
}

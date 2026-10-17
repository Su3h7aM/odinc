package amd64

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import x86 "core:rexcode/isa/x86"
import "oc:ir"
import "oc:regalloc"
import "oc:sched"
import "oc:types"

Select_Failure_Kind :: enum u8 {
	None,
	Unsupported_Node,
	Unsupported_Alignment,
	Malformed_Input,
	Out_Of_Memory,
	Unsupported_Signature,
}

@(private)
Select_Status :: union #shared_nil {
	Select_Failure_Kind,
	runtime.Allocator_Error,
	Abi_Error,
}

Select_Error :: struct {
	kind: Select_Failure_Kind,
	node: ir.Node_Id,
}

// Borrows verified IR, its schedule and ABI plan. Initializes output on success;
// destroy it with machine_function_destroy. Failures identify the offending node.
select_function :: proc(output: ^Machine_Function, input: ^ir.Function, schedule: ^sched.Schedule, plan: types.Abi_Plan) -> Select_Error {
	failed_node: ir.Node_Id
	status := select_function_impl(output, input, schedule, plan, &failed_node)
	switch value in status {
	case Select_Failure_Kind:
		return {value, failed_node}
	case runtime.Allocator_Error:
		return {.Out_Of_Memory, failed_node}
	case Abi_Error:
		return {.Unsupported_Signature, failed_node}
	}
	return {}
}

@(private)
Selector :: struct {
	input:      ^ir.Function,
	output:     ^Machine_Function,
	schedule:   ^sched.Schedule,
	allocator:  mem.Allocator,
	values:     []Vreg,
	tuples:     [][]Vreg,
	slots:      []u32,
	blocks:     []u32,
	edges:      [][]u32,
	current:    ir.Node_Id,
	block:      u32,
	signature:  ir.Signature,
	assignment: Assignment,
	params:     []Machine_Operand,
}

@(private)
select_function_impl :: proc(
	output: ^Machine_Function,
	input: ^ir.Function,
	schedule: ^sched.Schedule,
	plan: types.Abi_Plan,
	failed_node: ^ir.Node_Id,
) -> (
	err: Select_Status,
) {
	machine_function_init(output, input.name) or_return
	defer if err != nil { machine_function_destroy(output) }
	arena: virtual.Arena
	virtual.arena_init_growing(&arena) or_return
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	selector := Selector {
		input     = input,
		output    = output,
		schedule  = schedule,
		allocator = allocator,
		values    = make([]Vreg, len(input.nodes), allocator) or_return,
		tuples    = make([][]Vreg, len(input.nodes), allocator) or_return,
		slots     = make([]u32, len(input.nodes), allocator) or_return,
		blocks    = make([]u32, len(schedule.blocks), allocator) or_return,
		edges     = make([][]u32, len(schedule.blocks), allocator) or_return,
	}
	if len(schedule.blocks) == 0 || int(input.signature) >= len(input.signatures) {
		return Select_Failure_Kind.Malformed_Input
	}
	selector.signature = select_signature(plan, allocator) or_return
	defer if err != nil { failed_node^ = selector.current }
	selector.assignment = assign_signature(selector.signature, allocator) or_return
	for index in 1 ..< len(input.nodes) {
		if input.nodes.kind[index] == .Call {
			signature_index := input.nodes.data[index].index
			if int(signature_index) >= len(input.signatures) { return Select_Failure_Kind.Malformed_Input }
			assignment := assign_signature(input.signatures[signature_index], allocator) or_return
			output.outgoing_bytes = max(output.outgoing_bytes, ((assignment.stack_bytes + 15) & ~u32(15)))
		}
	}
	for block in schedule.blocks {
		index := add_block(output) or_return
		selector.blocks[block.id] = index
		output.blocks[index].depth = u8(min(block.depth, 255))
		output.blocks[index].cold = block.cold
	}
	for block in schedule.blocks {
		successors := ir.block_succs(schedule.cfg, block.id)
		selector.edges[block.id] = make([]u32, len(successors), allocator) or_return
		for successor, edge in successors {
			index := add_block(output) or_return
			selector.edges[block.id][edge] = index
			output.blocks[index].depth = u8(min(block.depth, 255))
			output.blocks[index].cold = block.cold
			append(&output.blocks[index].successors, selector.blocks[successor]) or_return
			output.blocks[index].edge_moves = make([][]regalloc.Move, 1, virtual.arena_allocator(&output.arena)) or_return
		}
	}
	for index in 1 ..< len(input.nodes) {
		node := ir.Node_Id(index)
		type := input.nodes.type[node]
		if type == .Memory || type == .Control || type == .Tuple || type == .None { continue }
		class, ok := register_class_of(type)
		if !ok || class == .Float && type != .F32 && type != .F64 { continue }
		selector.values[node] = new_vreg(output, class) or_return
	}
	selector.params = lower_start(output, 0, selector.signature, selector.assignment, allocator) or_return
	for block in schedule.blocks {
		selector.block = selector.blocks[block.id]
		for node in block.nodes {
			selector.current = node
			select_node(&selector, node) or_return
		}
		selector.current = schedule.cfg.exits[block.id]
		select_exit(&selector, block.id) or_return
	}
	for block in schedule.blocks {
		for successor, edge in ir.block_succs(schedule.cfg, block.id) {
			selector.block = selector.edges[block.id][edge]
			head := schedule.cfg.heads[successor]
			predecessors := ir.node_inputs(input, head)
			if input.nodes.kind[head] == .Loop || input.nodes.kind[head] == .Region {
				for predecessor, predecessor_index in predecessors {
					if schedule.cfg.block_of[predecessor] != block.id { continue }
					moves := make([dynamic]regalloc.Move, virtual.arena_allocator(&output.arena)) or_return
					for node in schedule.blocks[selector.blocks[successor]].nodes {
						if input.nodes.kind[node] != .Phi || input.nodes.type[node] == .Memory { continue }
						selector.current = node
						source := select_value(&selector, ir.node_input(input, node, predecessor_index + 1)) or_return
						append(&moves, regalloc.Move{source = source, destination = selector.values[node]}) or_return
					}
					output.blocks[selector.block].edge_moves[0] = moves[:]
				}
			}
			emit(output, selector.block, .JMP, 0, Block_Ref(selector.blocks[successor])) or_return
		}
	}
	return nil
}

@(private)
select_signature :: proc(plan: types.Abi_Plan, allocator: mem.Allocator) -> (signature: ir.Signature, err: Select_Status) {
	signature.cc = ir.Calling_Convention(plan.convention)
	signature.variadic = plan.variadic
	signature.params = make([]ir.Param, len(plan.params), allocator) or_return
	signature.results = make([]ir.Result, len(plan.results), allocator) or_return
	piece_types := [types.Abi_Piece]ir.Value_Type {
		.I8   = .I8,
		.I16  = .I16,
		.I32  = .I32,
		.I64  = .I64,
		.F16  = .F16,
		.F32  = .F32,
		.F64  = .F64,
		.V128 = .V128,
		.Ptr  = .Ptr,
	}
	for param, index in plan.params {
		signature.params[index] = {
			type  = piece_types[param.type],
			attr  = ir.Param_Attr(param.attr),
			ext   = ir.Extension(param.ext),
			size  = param.size,
			align = param.align,
		}
	}
	for result, index in plan.results {
		signature.results[index] = {
			type = piece_types[result.type],
			ext  = ir.Extension(result.ext),
			size = result.size,
		}
	}
	return
}

@(private)
select_failure :: proc(selector: ^Selector, kind := Select_Failure_Kind.Unsupported_Node) -> Select_Failure_Kind {
	return kind
}

@(private)
select_width :: proc(type: ir.Value_Type) -> u8 {
	#partial switch type {
	case .Bool, .I8:
		return 1
	case .I16:
		return 2
	case .I32:
		return 4
	case .F32:
		return 4
	case .I64, .Ptr:
		return 8
	case .F64:
		return 8
	}
	return 0
}

@(private)
select_value :: proc(selector: ^Selector, node: ir.Node_Id) -> (value: Vreg, err: Select_Status) {
	input, output, block := selector.input, selector.output, selector.block
	if node == ir.NODE_NONE || int(node) >= len(input.nodes) || select_width(input.nodes.type[node]) == 0 {
		return 0, select_failure(selector)
	}
	kind := input.nodes.kind[node]
	if .Rematerialize not_in ir.kind_info[kind].flags { return selector.values[node], nil }
	class := Register_Class.Int
	if got, is_register := register_class_of(input.nodes.type[node]); is_register {
		class = got
	}
	value = new_vreg(output, class) or_return
	#partial switch kind {
	case .Const_Int:
		constant := input.nodes.data[node].int_value
		width := max(4, select_width(input.nodes.type[node]))
		if width == 8 && constant >= 0 && constant <= i64(max(u32)) { width = 4 }
		mnemonic: x86.Mnemonic = .MOVABS if width == 8 && (constant < i64(min(i32)) || constant > i64(max(i32))) else .MOV
		emit(output, block, mnemonic, width, value, Immediate(constant)) or_return
	case .Const_Float:
		select_float_bits(selector, value, input.nodes.type[node], input.nodes.data[node].float_bits) or_return
	case .Symbol_Addr:
		emit(output, block, .LEA, 8, value, Memory_Ref{base = Symbol_Target{symbol = input.nodes.data[node].symbol}}) or_return
	case .Undef:
		if class == .Float {
			select_float_bits(selector, value, input.nodes.type[node], 0) or_return
		} else {
			emit(output, block, .MOV, 4, value, Immediate(0)) or_return
		}
	case:
		return 0, select_failure(selector)
	}
	return
}

@(private)
select_node :: proc(selector: ^Selector, node: ir.Node_Id) -> Select_Status {
	input := selector.input
	kind := input.nodes.kind[node]
	#partial switch kind {
	case .Start, .Stop, .Region, .Loop, .Phi, .If, .Switch, .Return, .Unreachable, .Trap:
		return nil
	case .Proj:
		if input.nodes.type[node] == .Control || input.nodes.type[node] == .Memory { return nil }
		source := ir.node_input(input, node, 0)
		index := input.nodes.data[node].index
		if source == input.start {
			if index < 2 || int(index - 2) >= len(selector.params) { return select_failure(selector, .Malformed_Input) }
			param := selector.params[index - 2]
			#partial switch value in param {
			case Vreg:
				return emit_pseudo(selector.output, selector.block, .Copy, selector.values[node], value)
			case Memory_Ref:
				if mnemonic, width, is_float := float_move(input.nodes.type[node]); is_float {
					return emit(selector.output, selector.block, mnemonic, width, selector.values[node], value)
				}
				mnemonic: x86.Mnemonic = .LEA if selector.signature.params[index - 2].attr == .By_Value else .MOV
				width := select_width(input.nodes.type[node])
				if width < 4 && mnemonic == .MOV { mnemonic = .MOVZX }
				return emit(selector.output, selector.block, mnemonic, width, selector.values[node], value)
			}
		} else if index > 0 && int(index) <= len(selector.tuples[source]) {
			return emit_pseudo(selector.output, selector.block, .Copy, selector.values[node], selector.tuples[source][index - 1])
		}
		return select_failure(selector, .Malformed_Input)
	case .Add, .Sub, .Mul, .And, .Or, .Xor, .Shl, .Shr, .Sar, .SDiv, .UDiv, .SRem, .URem, .Eq, .Ne, .SLt, .SLe, .ULt, .ULe, .Trunc, .Zext, .Sext:
		return select_integer(selector, node)
	case .Select, .Bitcast:
		return select_scalar(selector, node)
	case .FAdd,
	     .FSub,
	     .FMul,
	     .FDiv,
	     .FNeg,
	     .FSqrt,
	     .FEq,
	     .FNe,
	     .FLt,
	     .FLe,
	     .Sint_To_Float,
	     .Uint_To_Float,
	     .Float_To_Sint,
	     .Float_To_Uint,
	     .Float_Ext,
	     .Float_Trunc:
		return select_float(selector, node)
	case .Load, .Store, .Ptr_Offset, .Ptr_Index, .Stack_Slot, .Stack_Alloc, .Mem_Copy, .Mem_Set:
		return select_memory(selector, node)
	case .Call, .Syscall:
		return select_call(selector, node)
	case .Const_Int, .Const_Float, .Symbol_Addr, .Undef:
		return nil
	}
	return select_failure(selector)
}

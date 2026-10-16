package ir

import "base:runtime"

INTERP_SYSCALL_WRITE :: u64(1)
INTERP_SYSCALL_EXIT :: u64(60)
INTERP_SYSCALL_EBADF :: ~u64(0) - 8 // -9
INTERP_SYSCALL_ENOSYS :: ~u64(0) - 37 // -38

interp_function_index :: proc(module: ^Module, fn: ^Function) -> (u32, bool) {
	for function, index in module.functions {
		if function == fn {
			return u32(index), true
		}
	}
	return 0, false
}

@(private = "file")
interp_callee_index :: proc(machine: ^Interp_Machine, address: u64) -> (u32, bool) {
	for function_address, index in machine.function_addresses {
		if function_address == address {
			return u32(index), true
		}
	}
	return 0, false
}

// Runs one function in a new frame. The frame's stack allocations are released on return.
interp_frame :: proc(machine: ^Interp_Machine, function_index: u32, arguments: []u64) -> Interp_Result {
	fn := machine.module.functions[function_index]
	s := Interp_State {
		machine        = machine,
		fn             = fn,
		function_index = function_index,
		arguments      = arguments,
		generation     = 1,
	}
	if machine.depth == INTERP_MAX_DEPTH {
		interp_fail(&s, .Stack_Overflow, fn.start)
		return s.result
	}
	saved_top := machine.stack_top
	defer machine.stack_top = saved_top
	machine.depth += 1
	defer machine.depth -= 1
	if !interp_frame_setup(&s) {
		return s.result
	}
	return interp_walk(&s)
}

@(private = "file")
interp_frame_setup :: proc(s: ^Interp_State) -> bool {
	if err := interp_frame_allocate(s); err != nil {
		s.machine.err = err
		return false
	}
	for id in 1 ..< len(s.fn.nodes) {
		if s.fn.nodes.kind[id] != .Stack_Slot {
			continue
		}
		slot := node_slot(s.fn, Node_Id(id))
		address, ok := interp_stack_alloc(s.machine, u64(slot.size), u64(slot.align))
		if !ok {
			interp_fail(s, .Stack_Overflow, Node_Id(id))
			return false
		}
		s.slot_addresses[id] = address
	}
	return true
}

@(private = "file")
interp_frame_allocate :: proc(s: ^Interp_State) -> runtime.Allocator_Error {
	allocator := s.machine.allocator
	phi_count := 0
	for id in 1 ..< len(s.fn.nodes) {
		if s.fn.nodes.kind[id] == .Phi {
			phi_count += 1
		}
	}
	s.uses = uses_build(s.fn, allocator) or_return
	s.values = make([]u64, len(s.fn.nodes), allocator) or_return
	s.stamps = make([]u64, len(s.fn.nodes), allocator) or_return
	s.scratch = make([]u64, phi_count, allocator) or_return
	s.pending = make([]Node_Id, len(s.fn.nodes), allocator) or_return
	s.slot_addresses = make([]u64, len(s.fn.nodes), allocator) or_return
	return nil
}

// Arguments follow the caller's signature. `Indirect` passes the address as is; `By_Value` copies the
// aggregate into the frame of the call. Extensions are not modelled: values are canonical per type.
interp_call :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	fn := s.fn
	signature := fn.signatures[fn.nodes.data[id].index]
	callee_address := interp_operand(s, id, 2) or_return
	callee, found := interp_callee_index(s.machine, callee_address)
	if !found {
		interp_fail(s, .Unsupported, id)
		return 0, false
	}
	saved_top := s.machine.stack_top
	defer s.machine.stack_top = saved_top
	arguments, err := make([]u64, len(signature.params), s.machine.allocator)
	if err != nil {
		s.machine.err = err
		interp_fail(s, .Unsupported, id)
		return 0, false
	}
	for param, index in signature.params {
		argument := interp_operand(s, id, 3 + index) or_return
		if param.attr == .By_Value {
			copied, fits := interp_stack_alloc(s.machine, u64(param.size), u64(param.align))
			if !fits {
				interp_fail(s, .Stack_Overflow, id)
				return 0, false
			}
			if !interp_copy(s, id, copied, argument, u64(param.size)) {
				return 0, false
			}
			argument = copied
		}
		arguments[index] = argument
	}
	result := interp_frame(s.machine, callee, arguments)
	if result.outcome != .Value {
		s.result = Interp_Result {
			outcome = result.outcome,
			value   = result.value,
			node    = id,
		}
		return 0, false
	}
	return result.value, true
}

// A fake table: `write` to fd 1 appends to the captured output, `exit` reports the code; other
// numbers return -ENOSYS. Nothing reaches the host.
interp_syscall :: proc(s: ^Interp_State, id: Node_Id) -> (value: u64, ok: bool) {
	number := interp_operand(s, id, 2) or_return
	switch number {
	case INTERP_SYSCALL_WRITE:
		descriptor := interp_operand(s, id, 3) or_return
		buffer := interp_operand(s, id, 4) or_return
		count := interp_operand(s, id, 5) or_return
		if descriptor != 1 {
			return INTERP_SYSCALL_EBADF, true
		}
		offset, in_range := interp_range(s, id, buffer, count)
		if !in_range {
			return 0, false
		}
		if _, err := append(&s.machine.output, ..s.machine.memory[offset:offset + int(count)]); err != nil {
			s.machine.err = err
			interp_fail(s, .Unsupported, id)
			return 0, false
		}
		return count, true
	case INTERP_SYSCALL_EXIT:
		code := interp_operand(s, id, 3) or_return
		s.result = Interp_Result {
			outcome = .Exit,
			value   = code,
			node    = id,
		}
		return 0, false
	}
	return INTERP_SYSCALL_ENOSYS, true
}

interp_stack_alloc_node :: proc(s: ^Interp_State, id: Node_Id) -> (address: u64, ok: bool) {
	size := interp_operand(s, id, 1) or_return
	address, ok = interp_stack_alloc(s.machine, size, u64(s.fn.nodes.data[id].index))
	if !ok {
		interp_fail(s, .Stack_Overflow, id)
		return 0, false
	}
	return address, true
}

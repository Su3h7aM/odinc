package amd64

import "base:runtime"
import "core:mem"
import x86 "core:rexcode/isa/x86"
import "oc:ir"
import "oc:regalloc"

Abi_Failure :: enum u8 {
	None,
	// Unsupported_Signature: a piece type with no register class, or more result
	// pieces of one class than the return registers hold.
	Unsupported_Signature,
	// Argument_Count: the values given do not match the signature's pieces.
	Argument_Count,
}

Abi_Error :: union #shared_nil {
	Abi_Failure,
	runtime.Allocator_Error,
}

Location_Kind :: enum u8 {
	Register,
	Stack,
}

// Piece_Location is where one signature piece lives at the call boundary. For a
// register, `register` is the hardware number in `class`'s bank. For the stack,
// `offset` counts bytes from the start of the stack-argument area (`[rsp]` for the
// caller, `[rbp + 16]` for the callee) and `size` is the bytes the piece occupies.
Piece_Location :: struct {
	kind:     Location_Kind,
	class:    Register_Class,
	register: regalloc.Register,
	offset:   u32,
	size:     u32,
}

// Assignment is the System V placement of a signature as LLVM's calling-convention
// lowering does it: the pieces `types.plan_abi` decided on are placed one after the
// other, so a two-piece value can end up split between the last register and the stack.
Assignment :: struct {
	params:           []Piece_Location,
	results:          []Piece_Location,
	stack_bytes:      u32,
	vector_registers: u32,
}

INT_ARGUMENT_REGISTERS :: [6]Gpr{.RDI, .RSI, .RDX, .RCX, .R8, .R9}
INT_RESULT_REGISTERS :: [2]Gpr{.RAX, .RDX}
FLOAT_ARGUMENT_REGISTER_COUNT :: 8
FLOAT_RESULT_REGISTER_COUNT :: 2

// Largest `By_Value` object copied with inline loads and stores; larger ones use `rep movsb`.
INLINE_COPY_LIMIT :: 128

register_class_of :: proc(type: ir.Value_Type) -> (class: Register_Class, ok: bool) {
	#partial switch type {
	case .Bool, .I8, .I16, .I32, .I64, .Ptr:
		return .Int, true
	case .F16, .F32, .F64, .V128:
		return .Float, true
	}
	return .Int, false
}

// Places the pieces of `signature`; the slices are allocated with `allocator`.
assign_signature :: proc(signature: ir.Signature, allocator: mem.Allocator) -> (assignment: Assignment, err: Abi_Error) {
	params := make([]Piece_Location, len(signature.params), allocator) or_return
	results := make([]Piece_Location, len(signature.results), allocator) or_return
	int_used, float_used, cursor := 0, 0, u32(0)
	int_registers := INT_ARGUMENT_REGISTERS
	for param, index in signature.params {
		if param.attr == .By_Value {
			cursor = align_up(cursor, max(8, u32(param.align)))
			size := align_up(param.size, 8)
			params[index] = Piece_Location{.Stack, .Int, 0, cursor, size}
			cursor += size
			continue
		}
		class := Register_Class.Int
		if param.attr == .Direct {
			ok: bool
			class, ok = register_class_of(param.type)
			if !ok {
				return {}, Abi_Failure.Unsupported_Signature
			}
		}
		switch {
		case class == .Int && int_used < len(int_registers):
			params[index] = Piece_Location{.Register, .Int, regalloc.Register(int_registers[int_used]), 0, 8}
			int_used += 1
		case class == .Float && float_used < FLOAT_ARGUMENT_REGISTER_COUNT:
			params[index] = Piece_Location{.Register, .Float, regalloc.Register(float_used), 0, 16 if param.type == .V128 else 8}
			float_used += 1
		case:
			size := u32(16) if param.type == .V128 && param.attr == .Direct else 8
			cursor = align_up(cursor, max(size, u32(param.align)))
			params[index] = Piece_Location{.Stack, class, 0, cursor, size}
			cursor += size
		}
	}
	int_results, float_results := 0, 0
	result_registers := INT_RESULT_REGISTERS
	for result, index in signature.results {
		class, ok := register_class_of(result.type)
		if !ok {
			return {}, Abi_Failure.Unsupported_Signature
		}
		if class == .Int && int_results < len(result_registers) {
			results[index] = Piece_Location{.Register, .Int, regalloc.Register(result_registers[int_results]), 0, 8}
			int_results += 1
		} else if class == .Float && float_results < FLOAT_RESULT_REGISTER_COUNT {
			results[index] = Piece_Location{.Register, .Float, regalloc.Register(float_results), 0, 16 if result.type == .V128 else 8}
			float_results += 1
		} else {
			return {}, Abi_Failure.Unsupported_Signature
		}
	}
	return Assignment{params, results, align_up(cursor, 8), u32(float_used)}, nil
}

Callee :: union {
	Symbol_Target,
	Vreg,
}

// Defines the register parameters with one `Entry` pseudo and returns where each
// parameter piece is: a vreg for a register piece, the incoming memory otherwise
// (for `By_Value`, the object itself). `allocator` holds the returned slice and scratch.
lower_start :: proc(
	function: ^Machine_Function,
	block: u32,
	signature: ir.Signature,
	assignment: Assignment,
	allocator: mem.Allocator,
) -> (
	params: []Machine_Operand,
	err: Abi_Error,
) {
	params = make([]Machine_Operand, len(signature.params), allocator) or_return
	defined := make([dynamic]Machine_Operand, 0, len(params), allocator) or_return
	for location, index in assignment.params {
		if location.kind == .Stack {
			params[index] = Memory_Ref {
				base = Frame_Object{.Incoming, location.offset},
			}
			continue
		}
		vreg := new_vreg(function, location.class) or_return
		params[index] = vreg
		append(&defined, fixed(vreg, location.register, .Def)) or_return
	}
	emit_pseudo(function, block, .Entry, ..defined[:]) or_return
	for location, index in assignment.params {
		// An incoming register is caller-saved, so the piece must be handed out immediately:
		// keeping the pinned vreg for the body would leave it live across calls that destroy the register.
		if location.kind == .Stack {
			continue
		}
		handed := new_vreg(function, location.class) or_return
		emit_pseudo(function, block, .Copy, handed, params[index].(Vreg)) or_return
		params[index] = handed
	}
	return params, nil
}

// Emits the call sequence for `signature` and returns one vreg per result piece.
// `args` has one vreg per parameter piece; for `By_Value` it holds the address of the
// object. Stack pieces are stored first, register pieces become fixed operands of the
// `Call` pseudo, and a variadic callee gets the vector register count in `eax`. Results
// are `Fixed` defs at the `Call`, copied out to fresh vregs immediately: a result
// register is caller-saved, so the returned vregs must not live across a later call.
lower_call :: proc(
	function: ^Machine_Function,
	block: u32,
	signature: ir.Signature,
	assignment: Assignment,
	callee: Callee,
	args: []Vreg,
	allocator: mem.Allocator,
) -> (
	results: []Vreg,
	err: Abi_Error,
) {
	if len(args) != len(signature.params) {
		return nil, Abi_Failure.Argument_Count
	}
	operands := make([dynamic]Machine_Operand, 0, 2 + len(args) + len(signature.results), allocator) or_return
	switch target in callee {
	case Symbol_Target:
		append(&operands, target) or_return
	case Vreg:
		append(&operands, target) or_return
	case:
		return nil, Abi_Failure.Unsupported_Signature
	}
	for param, index in signature.params {
		location := assignment.params[index]
		if location.kind == .Stack {
			store_to_outgoing(function, block, param, location, args[index]) or_return
			continue
		}
		value := extend_piece(function, block, args[index], param.type, param.ext) or_return
		argument := new_vreg(function, location.class) or_return
		emit_pseudo(function, block, .Copy, argument, value) or_return
		append(&operands, fixed(argument, location.register, .Use)) or_return
	}
	if signature.variadic {
		count := new_vreg(function, .Int) or_return
		emit(function, block, .MOV, 4, count, Immediate(assignment.vector_registers)) or_return
		append(&operands, fixed(count, gpr(.RAX), .Use)) or_return
	}
	results = make([]Vreg, len(signature.results), allocator) or_return
	pinned := make([]Vreg, len(signature.results), allocator) or_return
	for location, index in assignment.results {
		pinned[index] = new_vreg(function, location.class) or_return
		append(&operands, fixed(pinned[index], location.register, .Def)) or_return
	}
	function.outgoing_bytes = max(function.outgoing_bytes, align_up(assignment.stack_bytes, 16))
	emit_instruction(
		function,
		block,
		Machine_Instruction{mnemonic = .CALL, pseudo = .Call, explicit_count = 1, operands = operands[:], clobbers = CALL_CLOBBERS},
	) or_return
	// A result register is caller-saved, so the hand-off copies each piece out of its
	// pinned vreg at once; the returned vregs may then live anywhere across later calls.
	for location, index in assignment.results {
		handed := new_vreg(function, location.class) or_return
		emit_pseudo(function, block, .Copy, handed, pinned[index]) or_return
		results[index] = handed
	}
	return results, nil
}

// Emits the return: results extended to 32 bits where the signature says so, moved to
// `rax rdx xmm0 xmm1` through fixed operands of the `Return` pseudo. A `Struct_Return`
// signature returns the incoming hidden pointer in `rax`, taken from `start_params`.
lower_return :: proc(
	function: ^Machine_Function,
	block: u32,
	signature: ir.Signature,
	assignment: Assignment,
	start_params: []Machine_Operand,
	values: []Vreg,
	allocator: mem.Allocator,
) -> Abi_Error {
	if len(values) != len(signature.results) || len(start_params) != len(signature.params) {
		return Abi_Failure.Argument_Count
	}
	operands := make([dynamic]Machine_Operand, 0, len(values) + 1, allocator) or_return
	for result, index in signature.results {
		location := assignment.results[index]
		value := extend_piece(function, block, values[index], result.type, result.ext) or_return
		copied := new_vreg(function, location.class) or_return
		emit_pseudo(function, block, .Copy, copied, value) or_return
		append(&operands, fixed(copied, location.register, .Use)) or_return
	}
	for param, index in signature.params {
		if param.attr != .Struct_Return {
			continue
		}
		pointer := new_vreg(function, .Int) or_return
		#partial switch source in start_params[index] {
		case Vreg:
			emit_pseudo(function, block, .Copy, pointer, source) or_return
		case Memory_Ref:
			emit(function, block, .MOV, 8, pointer, source) or_return
		case:
			return Abi_Failure.Argument_Count
		}
		append(&operands, fixed(pointer, gpr(.RAX), .Use)) or_return
	}
	emit_pseudo(function, block, .Return, ..operands[:]) or_return
	return nil
}

// Extends an `I8`, `I16` or `Bool` piece to 32 bits when the signature asks for it.
@(private = "file")
extend_piece :: proc(function: ^Machine_Function, block: u32, value: Vreg, type: ir.Value_Type, ext: ir.Extension) -> (result: Vreg, err: Abi_Error) {
	width: u8
	#partial switch type {
	case .Bool, .I8:
		width = 1
	case .I16:
		width = 2
	}
	if ext == .None || width == 0 {
		return value, nil
	}
	extended := new_vreg(function, .Int) or_return
	emit(function, block, .MOVZX if ext == .Zero else .MOVSX, width, extended, value) or_return
	return extended, nil
}

@(private = "file")
store_to_outgoing :: proc(function: ^Machine_Function, block: u32, param: ir.Param, location: Piece_Location, value: Vreg) -> Abi_Error {
	target := Memory_Ref {
		base = Frame_Object{.Outgoing, location.offset},
	}
	if param.attr == .By_Value {
		return copy_to_outgoing(function, block, value, location.offset, param.size)
	}
	if location.class == .Float {
		mnemonic: x86.Mnemonic = .MOVSS
		width := u8(4)
		#partial switch param.type {
		case .F64:
			mnemonic, width = .MOVSD, 8
		case .V128:
			mnemonic, width = .MOVUPS, 16
		}
		emit(function, block, mnemonic, width, target, value) or_return
		return nil
	}
	extended := extend_piece(function, block, value, param.type, param.ext) or_return
	emit(function, block, .MOV, 8, target, extended) or_return
	return nil
}

@(private = "file")
copy_to_outgoing :: proc(function: ^Machine_Function, block: u32, address: Vreg, offset: u32, size: u32) -> Abi_Error {
	if size > INLINE_COPY_LIMIT {
		destination := new_vreg(function, .Int) or_return
		source := new_vreg(function, .Int) or_return
		count := new_vreg(function, .Int) or_return
		emit(function, block, .LEA, 8, destination, Memory_Ref{base = Frame_Object{.Outgoing, offset}}) or_return
		emit_pseudo(function, block, .Copy, source, address) or_return
		emit(function, block, .MOV, 8, count, Immediate(size)) or_return
		operands := [?]Machine_Operand{fixed(destination, gpr(.RDI), .Use_Def), fixed(source, gpr(.RSI), .Use_Def), fixed(count, gpr(.RCX), .Use_Def)}
		emit_instruction(function, block, Machine_Instruction{mnemonic = .MOVSB, width = 1, rep = true, operands = operands[:]}) or_return
		return nil
	}
	for position := u32(0); position < size; {
		chunk := u32(8)
		for chunk > size - position {
			chunk /= 2
		}
		scratch := new_vreg(function, .Int) or_return
		from := Memory_Ref {
			base         = address,
			displacement = i32(position),
		}
		to := Memory_Ref {
			base = Frame_Object{.Outgoing, offset + position},
		}
		emit(function, block, .MOV, u8(chunk), scratch, from) or_return
		emit(function, block, .MOV, u8(chunk), to, scratch) or_return
		position += chunk
	}
	return nil
}

@(private = "file")
align_up :: proc(value, alignment: u32) -> u32 {
	return (value + alignment - 1) & ~(alignment - 1)
}

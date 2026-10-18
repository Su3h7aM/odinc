package ir

INPUTS_UNBOUNDED :: max(u16)

MAX_SLOTS :: 5
MAX_TUPLE_PREFIX :: 2

Node_Kind :: enum u8 {
	Invalid,
	Removed,
	Start,
	Stop,
	Region,
	Loop,
	If,
	Switch,
	Proj,
	Return,
	Unreachable,
	Trap,
	Const_Int,
	Const_Float,
	Undef,
	Symbol_Addr,
	Tls_Addr,
	Stack_Slot,
	Stack_Alloc,
	Phi,
	Add,
	Sub,
	Mul,
	And,
	Or,
	Xor,
	Shl,
	Shr,
	Sar,
	SDiv,
	UDiv,
	SRem,
	URem,
	Eq,
	Ne,
	SLt,
	SLe,
	ULt,
	ULe,
	FEq,
	FLt,
	FLe,
	FNe,
	FAdd,
	FSub,
	FMul,
	FDiv,
	FNeg,
	FSqrt,
	Select,
	Trunc,
	Zext,
	Sext,
	Bitcast,
	Sint_To_Float,
	Uint_To_Float,
	Float_To_Sint,
	Float_To_Uint,
	Float_Ext,
	Float_Trunc,
	Popcnt,
	Clz,
	Ctz,
	Bswap,
	Mul_Hi_S,
	Mul_Hi_U,
	Ptr_Offset,
	Ptr_Index,
	Load,
	Load_Ordered,
	Store,
	Atomic_Rmw,
	Atomic_Cas,
	Fence,
	Mem_Copy,
	Mem_Set,
	Call,
	Syscall,
	Target_Op,
}

NODE_KIND_COUNT :: 77 + 2

Kind_Class :: enum u8 {
	Unused,
	Boundary,
	Head,
	Branch,
	Projection,
	Terminator,
	Pure,
	Pinned,
	Phi,
}

Kind_Flag :: enum u8 {
	Commutative,
	Rematerialize,
}

Kind_Flags :: bit_set[Kind_Flag;u8]

Tuple_Shape :: enum u8 {
	None,
	// `members[:member_count]` is the whole tuple.
	Exact,
	// `members[:member_count]` leads; the rest comes from the signature,
	// case table, target operation or operand types.
	Open,
}

// Slots at or beyond the first empty `slots` entry (or `MAX_SLOTS`) take `tail`.
Kind_Info :: struct {
	name:         string,
	class:        Kind_Class,
	flags:        Kind_Flags,
	min_inputs:   u16,
	max_inputs:   u16,
	slots:        [MAX_SLOTS]Type_Set,
	tail:         Type_Set,
	result:       Type_Set,
	tuple:        Tuple_Shape,
	members:      [MAX_TUPLE_PREFIX]Value_Type,
	member_count: u8,
}

Target_Op :: enum u32 {
	Cpuid,
	Xgetbv,
	Pause,
	Debug_Trap,
	Rdtsc,
}

// Arguments follow the control and memory inputs; results follow the memory member.
Target_Op_Info :: struct {
	name:         string,
	arg_count:    u8,
	args:         [2]Value_Type,
	result_count: u8,
	results:      [4]Value_Type,
}

@(rodata)
target_op_info := [Target_Op]Target_Op_Info {
	.Cpuid = {name = "cpuid", arg_count = 2, args = {.I32, .I32}, result_count = 4, results = {.I32, .I32, .I32, .I32}},
	.Xgetbv = {name = "xgetbv", arg_count = 1, args = {.I32, .None}, result_count = 2, results = {.I32, .I32, .None, .None}},
	.Pause = {name = "pause"},
	.Debug_Trap = {name = "debug_trap"},
	.Rdtsc = {name = "rdtsc", result_count = 1, results = {.I64, .None, .None, .None}},
}

@(rodata)
kind_info := KIND_TABLE

is_pure :: proc "contextless" (kind: Node_Kind) -> bool {
	return kind_info[kind].class == .Pure
}

is_pinned :: proc "contextless" (kind: Node_Kind) -> bool {
	return kind_info[kind].class in Pinned_Classes
}

input_types :: proc "contextless" (kind: Node_Kind, slot: int) -> Type_Set {
	info := &kind_info[kind]
	if slot < MAX_SLOTS && info.slots[slot] != {} {
		return info.slots[slot]
	}
	return info.tail
}

Pinned_Classes :: bit_set[Kind_Class]{.Branch, .Terminator, .Pinned}

#assert(len(Node_Kind) == NODE_KIND_COUNT)
#assert(Node_Kind.Invalid == Node_Kind(0))
#assert(KIND_TABLE[.Loop].min_inputs == 2 && KIND_TABLE[.Loop].max_inputs == 2)
#assert(KIND_TABLE[.Region].min_inputs == 2 && KIND_TABLE[.Region].max_inputs == INPUTS_UNBOUNDED)
#assert(KIND_TABLE[.Phi].min_inputs == 3 && KIND_TABLE[.Phi].slots[0] == CONTROL)
#assert(KIND_TABLE[.Stop].class == .Boundary)
#assert(KIND_TABLE[.Start].member_count == 2)
#assert(KIND_TABLE[.Stop].max_inputs == INPUTS_UNBOUNDED)
#assert(KIND_TABLE[.If].tuple == .Exact && KIND_TABLE[.Switch].tuple == .Open)

@(private = "file")
CONTROL :: Type_Set{.Control}
@(private = "file")
MEMORY :: Type_Set{.Memory}
@(private = "file")
TUPLE :: Type_Set{.Tuple}
@(private = "file")
NOTHING :: Type_Set{.None}
@(private = "file")
BOOL :: Type_Set{.Bool}
@(private = "file")
I8 :: Type_Set{.I8}
@(private = "file")
I64 :: Type_Set{.I64}
@(private = "file")
PTR :: Type_Set{.Ptr}
@(private = "file")
INTS :: Type_Set{.I8, .I16, .I32, .I64}
@(private = "file")
BOOL_INTS :: INTS + BOOL
@(private = "file")
FLOATS :: Type_Set{.F16, .F32, .F64}
@(private = "file")
ARITH_FLOATS :: Type_Set{.F32, .F64}
@(private = "file")
SCALARS :: INTS + FLOATS + BOOL + PTR
@(private = "file")
VECTOR :: Type_Set{.V128}

ABI_VALUES :: SCALARS + VECTOR

STORABLE :: INTS + FLOATS + PTR + VECTOR
@(private = "file")
BITCASTABLE :: INTS + FLOATS + PTR
@(private = "file")
EQUATABLE :: BOOL_INTS + PTR

@(private = "file")
KIND_TABLE :: [Node_Kind]Kind_Info {
	.Invalid = {name = "invalid", class = .Unused, result = NOTHING},
	.Removed = {name = "removed", class = .Unused, result = NOTHING},
	.Start = {name = "start", class = .Boundary, result = TUPLE, tuple = .Open, members = {.Control, .Memory}, member_count = 2},
	.Stop = {name = "stop", class = .Boundary, max_inputs = INPUTS_UNBOUNDED, tail = NOTHING, result = NOTHING},
	.Region = {name = "region", class = .Head, min_inputs = 2, max_inputs = INPUTS_UNBOUNDED, tail = CONTROL, result = CONTROL},
	.Loop = {name = "loop", class = .Head, min_inputs = 2, max_inputs = 2, slots = {CONTROL, CONTROL, {}, {}, {}}, result = CONTROL},
	.If = {
		name = "if",
		class = .Branch,
		min_inputs = 2,
		max_inputs = 2,
		slots = {CONTROL, BOOL, {}, {}, {}},
		result = TUPLE,
		tuple = .Exact,
		members = {.Control, .Control},
		member_count = 2,
	},
	.Switch = {name = "switch", class = .Branch, min_inputs = 2, max_inputs = 2, slots = {CONTROL, INTS, {}, {}, {}}, result = TUPLE, tuple = .Open},
	.Proj = {name = "proj", class = .Projection, min_inputs = 1, max_inputs = 1, slots = {TUPLE, {}, {}, {}, {}}, result = CONTROL + MEMORY + SCALARS},
	.Return = {
		name = "return",
		class = .Terminator,
		min_inputs = 2,
		max_inputs = 4,
		slots = {CONTROL, MEMORY, {}, {}, {}},
		tail = ABI_VALUES,
		result = NOTHING,
	},
	.Unreachable = {name = "unreachable", class = .Terminator, min_inputs = 2, max_inputs = 2, slots = {CONTROL, MEMORY, {}, {}, {}}, result = NOTHING},
	.Trap = {name = "trap", class = .Terminator, min_inputs = 2, max_inputs = 2, slots = {CONTROL, MEMORY, {}, {}, {}}, result = NOTHING},
	.Const_Int = {name = "const_int", class = .Pure, flags = {.Rematerialize}, result = BOOL_INTS + PTR},
	.Const_Float = {name = "const_float", class = .Pure, flags = {.Rematerialize}, result = FLOATS},
	.Undef = {name = "undef", class = .Pure, flags = {.Rematerialize}, result = SCALARS},
	.Symbol_Addr = {name = "symbol_addr", class = .Pure, flags = {.Rematerialize}, result = PTR},
	.Tls_Addr = {name = "tls_addr", class = .Pure, flags = {.Rematerialize}, result = PTR},
	.Stack_Slot = {name = "stack_slot", class = .Pinned, min_inputs = 1, max_inputs = 1, slots = {CONTROL, {}, {}, {}, {}}, result = PTR},
	.Stack_Alloc = {name = "stack_alloc", class = .Pinned, min_inputs = 2, max_inputs = 2, slots = {CONTROL, I64, {}, {}, {}}, result = PTR},
	.Phi = {
		name = "phi",
		class = .Phi,
		min_inputs = 3,
		max_inputs = INPUTS_UNBOUNDED,
		slots = {CONTROL, {}, {}, {}, {}},
		tail = MEMORY + SCALARS,
		result = MEMORY + SCALARS,
	},
	.Add = {name = "add", class = .Pure, flags = {.Commutative}, min_inputs = 2, max_inputs = 2, slots = {INTS, INTS, {}, {}, {}}, result = INTS},
	.Sub = {name = "sub", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {INTS, INTS, {}, {}, {}}, result = INTS},
	.Mul = {name = "mul", class = .Pure, flags = {.Commutative}, min_inputs = 2, max_inputs = 2, slots = {INTS, INTS, {}, {}, {}}, result = INTS},
	.And = {
		name = "and",
		class = .Pure,
		flags = {.Commutative},
		min_inputs = 2,
		max_inputs = 2,
		slots = {BOOL_INTS, BOOL_INTS, {}, {}, {}},
		result = BOOL_INTS,
	},
	.Or = {name = "or", class = .Pure, flags = {.Commutative}, min_inputs = 2, max_inputs = 2, slots = {BOOL_INTS, BOOL_INTS, {}, {}, {}}, result = BOOL_INTS},
	.Xor = {
		name = "xor",
		class = .Pure,
		flags = {.Commutative},
		min_inputs = 2,
		max_inputs = 2,
		slots = {BOOL_INTS, BOOL_INTS, {}, {}, {}},
		result = BOOL_INTS,
	},
	.Shl = {name = "shl", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {INTS, INTS, {}, {}, {}}, result = INTS},
	.Shr = {name = "shr", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {INTS, INTS, {}, {}, {}}, result = INTS},
	.Sar = {name = "sar", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {INTS, INTS, {}, {}, {}}, result = INTS},
	.SDiv = {name = "sdiv", class = .Pinned, min_inputs = 3, max_inputs = 3, slots = {CONTROL, INTS, INTS, {}, {}}, result = INTS},
	.UDiv = {name = "udiv", class = .Pinned, min_inputs = 3, max_inputs = 3, slots = {CONTROL, INTS, INTS, {}, {}}, result = INTS},
	.SRem = {name = "srem", class = .Pinned, min_inputs = 3, max_inputs = 3, slots = {CONTROL, INTS, INTS, {}, {}}, result = INTS},
	.URem = {name = "urem", class = .Pinned, min_inputs = 3, max_inputs = 3, slots = {CONTROL, INTS, INTS, {}, {}}, result = INTS},
	.Eq = {name = "eq", class = .Pure, flags = {.Commutative}, min_inputs = 2, max_inputs = 2, slots = {EQUATABLE, EQUATABLE, {}, {}, {}}, result = BOOL},
	.Ne = {name = "ne", class = .Pure, flags = {.Commutative}, min_inputs = 2, max_inputs = 2, slots = {EQUATABLE, EQUATABLE, {}, {}, {}}, result = BOOL},
	.SLt = {name = "slt", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {INTS, INTS, {}, {}, {}}, result = BOOL},
	.SLe = {name = "sle", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {INTS, INTS, {}, {}, {}}, result = BOOL},
	.ULt = {name = "ult", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {INTS, INTS, {}, {}, {}}, result = BOOL},
	.ULe = {name = "ule", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {INTS, INTS, {}, {}, {}}, result = BOOL},
	.FEq = {name = "feq", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {ARITH_FLOATS, ARITH_FLOATS, {}, {}, {}}, result = BOOL},
	.FLt = {name = "flt", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {ARITH_FLOATS, ARITH_FLOATS, {}, {}, {}}, result = BOOL},
	.FLe = {name = "fle", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {ARITH_FLOATS, ARITH_FLOATS, {}, {}, {}}, result = BOOL},
	.FNe = {name = "fne", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {ARITH_FLOATS, ARITH_FLOATS, {}, {}, {}}, result = BOOL},
	.FAdd = {name = "fadd", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {ARITH_FLOATS, ARITH_FLOATS, {}, {}, {}}, result = ARITH_FLOATS},
	.FSub = {name = "fsub", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {ARITH_FLOATS, ARITH_FLOATS, {}, {}, {}}, result = ARITH_FLOATS},
	.FMul = {name = "fmul", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {ARITH_FLOATS, ARITH_FLOATS, {}, {}, {}}, result = ARITH_FLOATS},
	.FDiv = {name = "fdiv", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {ARITH_FLOATS, ARITH_FLOATS, {}, {}, {}}, result = ARITH_FLOATS},
	.FNeg = {name = "fneg", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {ARITH_FLOATS, {}, {}, {}, {}}, result = ARITH_FLOATS},
	.FSqrt = {name = "fsqrt", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {ARITH_FLOATS, {}, {}, {}, {}}, result = ARITH_FLOATS},
	.Select = {name = "select", class = .Pure, min_inputs = 3, max_inputs = 3, slots = {BOOL, SCALARS, SCALARS, {}, {}}, result = SCALARS},
	.Trunc = {name = "trunc", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {INTS, {}, {}, {}, {}}, result = BOOL_INTS},
	.Zext = {name = "zext", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {BOOL_INTS, {}, {}, {}, {}}, result = INTS},
	.Sext = {name = "sext", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {INTS, {}, {}, {}, {}}, result = INTS},
	.Bitcast = {name = "bitcast", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {BITCASTABLE, {}, {}, {}, {}}, result = BITCASTABLE},
	.Sint_To_Float = {name = "sint_to_float", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {INTS, {}, {}, {}, {}}, result = FLOATS},
	.Uint_To_Float = {name = "uint_to_float", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {INTS, {}, {}, {}, {}}, result = FLOATS},
	.Float_To_Sint = {name = "float_to_sint", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {FLOATS, {}, {}, {}, {}}, result = INTS},
	.Float_To_Uint = {name = "float_to_uint", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {FLOATS, {}, {}, {}, {}}, result = INTS},
	.Float_Ext = {name = "float_ext", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {FLOATS, {}, {}, {}, {}}, result = FLOATS},
	.Float_Trunc = {name = "float_trunc", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {FLOATS, {}, {}, {}, {}}, result = FLOATS},
	.Popcnt = {name = "popcnt", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {INTS, {}, {}, {}, {}}, result = INTS},
	.Clz = {name = "clz", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {INTS, {}, {}, {}, {}}, result = INTS},
	.Ctz = {name = "ctz", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {INTS, {}, {}, {}, {}}, result = INTS},
	.Bswap = {name = "bswap", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {INTS, {}, {}, {}, {}}, result = INTS},
	.Mul_Hi_S = {name = "mul_hi_s", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {I64, I64, {}, {}, {}}, result = I64},
	.Mul_Hi_U = {name = "mul_hi_u", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {I64, I64, {}, {}, {}}, result = I64},
	.Ptr_Offset = {name = "ptr_offset", class = .Pure, min_inputs = 1, max_inputs = 1, slots = {PTR, {}, {}, {}, {}}, result = PTR},
	.Ptr_Index = {name = "ptr_index", class = .Pure, min_inputs = 2, max_inputs = 2, slots = {PTR, I64, {}, {}, {}}, result = PTR},
	.Load = {name = "load", class = .Pinned, min_inputs = 3, max_inputs = 3, slots = {CONTROL, MEMORY, PTR, {}, {}}, result = STORABLE},
	.Load_Ordered = {
		name = "load_ordered",
		class = .Pinned,
		min_inputs = 3,
		max_inputs = 3,
		slots = {CONTROL, MEMORY, PTR, {}, {}},
		result = TUPLE,
		tuple = .Open,
		members = {.Memory, .None},
		member_count = 1,
	},
	.Store = {name = "store", class = .Pinned, min_inputs = 4, max_inputs = 4, slots = {CONTROL, MEMORY, PTR, STORABLE, {}}, result = MEMORY},
	.Atomic_Rmw = {
		name = "atomic_rmw",
		class = .Pinned,
		min_inputs = 4,
		max_inputs = 4,
		slots = {CONTROL, MEMORY, PTR, INTS, {}},
		result = TUPLE,
		tuple = .Open,
		members = {.Memory, .None},
		member_count = 1,
	},
	.Atomic_Cas = {
		name = "atomic_cas",
		class = .Pinned,
		min_inputs = 5,
		max_inputs = 5,
		slots = {CONTROL, MEMORY, PTR, INTS, INTS},
		result = TUPLE,
		tuple = .Open,
		members = {.Memory, .None},
		member_count = 1,
	},
	.Fence = {name = "fence", class = .Pinned, min_inputs = 2, max_inputs = 2, slots = {CONTROL, MEMORY, {}, {}, {}}, result = MEMORY},
	.Mem_Copy = {name = "mem_copy", class = .Pinned, min_inputs = 5, max_inputs = 5, slots = {CONTROL, MEMORY, PTR, PTR, I64}, result = MEMORY},
	.Mem_Set = {name = "mem_set", class = .Pinned, min_inputs = 5, max_inputs = 5, slots = {CONTROL, MEMORY, PTR, I8, I64}, result = MEMORY},
	.Call = {
		name = "call",
		class = .Pinned,
		min_inputs = 3,
		max_inputs = INPUTS_UNBOUNDED,
		slots = {CONTROL, MEMORY, PTR, {}, {}},
		tail = ABI_VALUES,
		result = TUPLE,
		tuple = .Open,
		members = {.Memory, .None},
		member_count = 1,
	},
	.Syscall = {
		name = "syscall",
		class = .Pinned,
		min_inputs = 3,
		max_inputs = 9,
		slots = {CONTROL, MEMORY, I64, {}, {}},
		tail = I64,
		result = TUPLE,
		tuple = .Exact,
		members = {.Memory, .I64},
		member_count = 2,
	},
	.Target_Op = {
		name = "target_op",
		class = .Pinned,
		min_inputs = 2,
		max_inputs = 4,
		slots = {CONTROL, MEMORY, {}, {}, {}},
		tail = INTS,
		result = TUPLE,
		tuple = .Open,
		members = {.Memory, .None},
		member_count = 1,
	},
}

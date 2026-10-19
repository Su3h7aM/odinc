// Package regalloc assigns machine registers to the virtual registers of a
// scheduled, selected function.
//
// The interface is data only: a `Program` describes the function as blocks of
// instructions whose operands read and write virtual registers under
// x86-64-shaped constraints (operand early/late positions, fixed registers,
// reuse-input two-address form, call clobber sets), and `allocate` returns
// where each virtual register lives and which moves the emitter must insert.
//
// Model (revision 2 of `docs/archive/02-ir-design.md`, section 12): no interval
// splitting. A virtual register has one location for its whole life, a
// register or a spill slot. The emitter reaches a spilled operand through
// its scratch registers, which are absent from `Program.allocatable`. Fixed
// registers are met by assignment, never by moves: `x64` gives every fixed
// operand a short-lived vreg of its own, and a program whose fixed operands
// cannot all be honored is an error, not a fixup.
// The package imports nothing from `ir` or `x64`, so the allocator can be
// replaced without touching either.
//
// References that informed the design: Poletto & Sarkar, "Linear Scan
// Register Allocation", TOPLAS 21(5), 1999, the base algorithm of
// `linear_scan.odin`; Wimmer & Franz, "Linear Scan Register Allocation on SSA
// Form", 2010, the live-interval-per-vreg model of `liveness.odin`;
// `docs/archive/research/06-pr7850-ir-regalloc-parallelism.md` section 2.4 for the
// register-choice and spill-cost heuristics (caller-saved unless a call
// overlaps the interval, spill by cost, coalescing hints);
// `docs/archive/research/02-backend-ir-landscape.md` sections 4.3 and 7.2 for the
// constraint model (early/late positions, reuse-input, fixed registers);
// the implementation of PR #7850, `refs/odin-pr7850-fast-backend/src/xb_analysis.cpp`
// lines 518-1191, as the behaviour reference for the loop-weight and
// interval-shape rules.
//
// Memory rules follow the repository convention (`src/elf/doc.odin`):
// every procedure takes an explicit allocator, everything it allocates is
// freed before it returns, and a zero `Program` is inert.
package regalloc

// Vreg names one virtual register. Ids are 0-based and dense: a program with
// n virtual registers names them 0 .. n-1. There is no reserved sentinel, so
// operand fields that mean "none" use a separate boolean instead.
Vreg :: distinct u32

// Register_Class separates the register banks. The classes are disjoint by
// construction: a vreg belongs to exactly one, given once by `Program.classes`.
Register_Class :: enum u8 {
	// Int is the general-purpose bank (16 registers on x86-64).
	Int,
	// Float is the vector/SSE bank (16 registers on x86-64).
	Float,
}

REGISTER_CLASS_COUNT :: len(Register_Class)


// Register names a machine register by its number within its bank. Register
// 0 of `Int` is the first general-purpose register the caller may use for
// allocation; the caller excludes unusable registers (stack pointer, reserved)
// from `Program.allocatable` instead of reserving number 0 here.
Register :: distinct u8

// The highest register number either bank may name. A register set is a
// bit_set over [0, REGISTER_LIMIT) backed by one u64.
REGISTER_LIMIT :: 64

// Register_Set is a set of machine register numbers, usable for both banks.
// All of this package's sets (allocatable, callee-saved, clobbers) use it.
Register_Set :: bit_set[0 ..< REGISTER_LIMIT;u64]

// Constraint restricts which register an operand may use.
Constraint :: enum u8 {
	// Any: any allocatable register of the operand's class.
	Any,
	// Fixed: the one register named by `Operand.fixed`.
	Fixed,
	// Reuse_Input: at the late position the operand must be in the register
	// that its input operand, the one numbered `Operand.reuse`, holds at the
	// early position. This is the two-address form of x86-64 (`add rax, rbx`
	// reads and writes its first operand).
	Reuse_Input,
}

// Position tells when, within one instruction, an operand is read or written.
// Uses happen early, defs happen late, and a use-def is split: read at the
// early position, written at the late one. A vreg live across an instruction
// (neither read nor written) occupies its register at both positions, so two
// intervals may only share a register when neither instruction position
// between them overlaps.
Position :: enum u8 {
	Early,
	Late,
}

// Operand_Role says what an instruction does with a virtual register.
Operand_Role :: enum u8 {
	// Use reads the vreg (early position).
	Use,
	// Def writes the vreg (late position).
	Def,
	// Use_Def reads and writes the vreg (read early, written late).
	Use_Def,
}

// Operand is one read or write of a virtual register by an instruction.
Operand :: struct {
	// vreg is the virtual register this operand touches.
	vreg:       Vreg,
	// role says whether it is read, written, or both.
	role:       Operand_Role,
	// position is when the access happens; a Use_Def splits into read-early,
	// write-late.
	position:   Position,
	// constraint restricts the register: see `Constraint`.
	constraint: Constraint,
	// fixed names the register of a .Fixed constraint; ignored otherwise.
	fixed:      Register,
	// reuse is the input operand number a .Reuse_Input constraint binds to;
	// ignored otherwise.
	reuse:      u8,
}

// Move is a register-to-register copy requested by an instruction
// (`Instruction.is_move`) or produced by allocation: `source` and
// `destination` name vregs, and the emitter materializes the move between
// the locations the result assigns to them.
Move :: struct {
	source:      Vreg,
	destination: Vreg,
}

// Instruction is one scheduled machine instruction with every register
// constraint spelled out as data. The operand list order is the operand
// numbering that .Reuse_Input refers to.
Instruction :: struct {
	// operands are the virtual registers read and written, in operand order.
	operands: []Operand,
	// clobbers are the machine registers this instruction destroys without
	// recording as a def, per register class; calls carry the caller-saved
	// sets here.
	clobbers: [Register_Class]Register_Set,
	// is_call marks a call: the allocator prefers callee-saved registers for
	// any interval overlapping one, and a clobbered register cannot be live
	// across it.
	is_call:  bool,
	// is_move marks a pure register copy `dst <- src` with exactly one Use and
	// one Def operand; the allocator uses it as a coalescing hint and may
	// give both vregs one register.
	is_move:  bool,
}

// Block is a basic block in the order the emitter lays it out (entry first,
// loop bodies contiguous, cold paths last).
Block :: struct {
	// instructions are the block's instructions in final order.
	instructions: []Instruction,
	// successors are the block's successor block numbers.
	successors:   []u32,
	// edge_moves are the parallel copies on the edge to successor i, empty
	// for none; the emitter places them at the end of the predecessor.
	edge_moves:   [][]Move,
	// depth is the loop-nesting depth of the block; 0 is outside every loop.
	// It weights spill cost: a reference inside a loop is worth more than one
	// outside it.
	depth:        u8,
}

// Program is a function as the allocator sees it: blocks, the class of every
// virtual register, and the register sets that describe the machine's rules.
// All slices are borrowed; the program must outlive the allocation.
Program :: struct {
	// blocks are the function's blocks in emission order; block 0 is entry.
	blocks:       []Block,
	// classes gives the register class of each vreg, indexed by vreg.
	classes:      []Register_Class,
	// allocatable is, per class, the set of registers the allocator may hand
	// out. The caller has already removed the stack pointer and any register
	// the operating system or the runtime reserves.
	allocatable:  [Register_Class]Register_Set,
	// callee_saved is, per class, the set of registers a call preserves. The
	// allocator prefers these for intervals that overlap a call so nothing
	// needs a save and restore; registers in `callee_saved` are always also
	// in `allocatable`.
	callee_saved: [Register_Class]Register_Set,
	// scratch is, per class, the reserved registers outside `allocatable` the
	// resolver of the edge copies may use as a temporary; it uses the first
	// one. A class with no scratch register breaks a cycle through a spill
	// slot instead, so the zero value is valid.
	scratch:      [Register_Class]Register_Set,
}

// Spill_Slot names one slot of the function's frame; slots are numbered 0,
// 1, 2, ... below `Result.spill_slot_count`. Every slot is the same fixed
// width; the emitter owns the width.
Spill_Slot :: distinct u32

// Location is where a virtual register lives.
Location :: union {
	Register,
	Spill_Slot,
}

// Move_At is a move the emitter performs immediately before instruction
// `before` of block `block`. Only reuse-input needs one: when the input of a
// two-address instruction does not already share the register of the def,
// `destination <- source` runs first and the instruction then reads and
// writes the destination.
Move_At :: struct {
	block:  u32,
	before: u32,
	move:   Move,
}

// Edge_Copy is one sequential copy `resolve_edge_moves` produced from a
// block's simultaneous `edge_moves`. It runs before instruction `before` of
// `block`, so the branch the block ends with sees the finished copies, and its
// endpoints are locations: the allocation of the parallel copy's vregs, or a
// temporary one of them passed through.
Edge_Copy :: struct {
	block:       u32,
	before:      u32,
	class:       Register_Class,
	source:      Location,
	destination: Location,
}

// Result is the allocator's answer. Zero value means "empty program, nothing
// allocated". Free it with `result_destroy`.
Result :: struct {
	// location is, per vreg, where it lives for its whole life: one register
	// or one spill slot. Indexed by vreg; a vreg no instruction names has no
	// location.
	location:          []Location,
	// inserted_moves are the reuse-input copies, sorted by block, then
	// position, then operand order.
	inserted_moves:    []Move_At,
	// edge_copies are the sequential edge copies, sorted by block, then
	// position, then program order; nil until `resolve_edge_moves` produced
	// them, so resolving twice keeps the first answer instead of duplicating
	// the copies.
	edge_copies:       []Edge_Copy,
	// spill_slot_count is the number of spill slots the frame needs.
	spill_slot_count:  u32,
	// callee_saved_used is, per class, the callee-saved registers some vreg
	// lives in; the prologue must save and restore exactly these.
	callee_saved_used: [Register_Class]Register_Set,
}

// result_destroy frees what `allocate` returned. Safe on a zero Result.
result_destroy :: proc(result: ^Result, allocator := context.allocator) {
	delete(result.location, allocator)
	delete(result.inserted_moves, allocator)
	delete(result.edge_copies, allocator)
	result^ = {}
}

// Allocation_Error enumerates the ways a program cannot be allocated.
// The zero value None means success.
Allocation_Error :: enum u8 {
	None,
	// Unknown_Vreg: an operand names a vreg at or past the class table length.
	Unknown_Vreg,
	// Unallocatable_Fixed: a .Fixed operand names a register outside the
	// allocatable set of its class, or outside the register range.
	Unallocatable_Fixed,
	// Reuse_Not_Use: a .Reuse_Input operand's reuse index does not name a Use
	// operand of the same instruction.
	Reuse_Not_Use,
	// Unknown_Block: a successor names a block past the block list.
	Unknown_Block,
	// Used_Before_Defined: a vreg is live at the entry of block 0.
	Used_Before_Defined,
	// Conflicting_Fixed: one vreg carries fixed operands of two registers.
	Conflicting_Fixed,
	// No_Register_Available: a vreg that cannot be spilled (it has a fixed
	// operand) finds no register.
	No_Register_Available,
	// Bad_Location: `verify` found a missing, out-of-range or unallocatable
	// location, or `resolve_edge_moves` found an edge copy whose endpoints
	// have no location or disagree about the register class.
	Bad_Location,
	// Register_Conflict: `verify` found two vregs live together in one register.
	Register_Conflict,
	// Fixed_Violated: `verify` found a fixed operand outside its register.
	Fixed_Violated,
	// Reuse_Violated: `verify` found a reuse-input pair neither sharing a
	// register nor served by an inserted move.
	Reuse_Violated,
	// Clobber_Violated: `verify` found a vreg live across an instruction
	// that destroys its register.
	Clobber_Violated,
	// Out_Of_Memory: an allocation failed.
	Out_Of_Memory,
}

// Error is the allocator's error value: an allocation error plus the vreg it
// concerns, or an out-of-memory value.
Error :: struct {
	kind: Allocation_Error,
	vreg: Vreg,
}

// error_string returns the name of an allocation error kind.
error_string :: proc(kind: Allocation_Error) -> string {
	switch kind {
	case .None:
		return "None"
	case .Unknown_Vreg:
		return "Unknown_Vreg"
	case .Unallocatable_Fixed:
		return "Unallocatable_Fixed"
	case .Reuse_Not_Use:
		return "Reuse_Not_Use"
	case .Unknown_Block:
		return "Unknown_Block"
	case .Used_Before_Defined:
		return "Used_Before_Defined"
	case .Conflicting_Fixed:
		return "Conflicting_Fixed"
	case .No_Register_Available:
		return "No_Register_Available"
	case .Bad_Location:
		return "Bad_Location"
	case .Register_Conflict:
		return "Register_Conflict"
	case .Fixed_Violated:
		return "Fixed_Violated"
	case .Reuse_Violated:
		return "Reuse_Violated"
	case .Clobber_Violated:
		return "Clobber_Violated"
	case .Out_Of_Memory:
		return "Out_Of_Memory"
	}
	return "Unknown"
}

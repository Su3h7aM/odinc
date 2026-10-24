package amd64

import x86 "core:rexcode/isa/x86"

Op_Access :: enum u8 {
	None,
	Use,
	Def,
}

// Op_Info describes the machine form of one mnemonic. `access` is the role of
// operand i when it is a virtual register; a memory operand always uses its base
// and index. `two_address` marks the machine form `op dst, src1, src2` that x86 runs
// as `dst = src1; op dst, src2`: the allocator gets a Reuse_Input constraint binding
// operand 0 to operand 1 (dropped when `reuse_unless_immediate` and the last operand is an immediate).
Op_Info :: struct {
	access:                 [4]Op_Access,
	two_address:            bool,
	reuse_unless_immediate: bool,
	writes_flags:           bool,
	reads_flags:            bool,
	branch:                 bool,
	terminator:             bool,
}

// Returns false for mnemonics `amd64` does not select.
op_info :: proc(mnemonic: x86.Mnemonic) -> (info: Op_Info, known: bool) {
	#partial switch mnemonic {
	case .MOV, .MOVABS, .MOVZX, .MOVSX, .MOVSXD, .LEA, .MOVSS, .MOVSD, .MOVUPS, .MOVAPS, .MOVD, .MOVQ, .SQRTSS, .SQRTSD, .RCPSS, .RSQRTSS:
		info.access = {.Def, .Use, .None, .None}
	case .CVTSI2SS, .CVTSI2SD, .CVTTSS2SI, .CVTTSD2SI, .CVTSS2SD, .CVTSD2SS:
		info.access = {.Def, .Use, .None, .None}
	case .ADD, .SUB, .AND, .OR, .XOR, .SHL, .SHR, .SAR:
		info.access = {.Def, .Use, .Use, .None}
		info.two_address = true
		info.writes_flags = true
	case .IMUL:
		info.access = {.Def, .Use, .Use, .None}
		info.two_address = true
		info.reuse_unless_immediate = true
		info.writes_flags = true
	case .NEG, .NOT, .BSWAP:
		info.access = {.Def, .Use, .None, .None}
		info.two_address = true
		info.writes_flags = mnemonic == .NEG
	case .BSR, .BSF, .POPCNT:
		info.access = {.Def, .Use, .None, .None}
		info.writes_flags = true
	case .ADDSS, .ADDSD, .SUBSS, .SUBSD, .MULSS, .MULSD, .DIVSS, .DIVSD, .XORPS:
		info.access = {.Def, .Use, .Use, .None}
		info.two_address = true
	case .CMOVE, .CMOVNE, .CMOVL, .CMOVLE, .CMOVG, .CMOVGE, .CMOVB, .CMOVBE, .CMOVA, .CMOVAE, .CMOVNS:
		info.access = {.Def, .Use, .Use, .None}
		info.two_address = true
		info.reads_flags = true
	case .AESENC, .AESENCLAST, .AESDEC, .AESDECLAST, .PSHUFB, .PCLMULQDQ:
		info.access = {.Def, .Use, .Use, .None}
		info.two_address = true
	case .SHA256MSG1, .SHA256MSG2:
		info.access = {.Def, .Use, .Use, .None}
		info.two_address = true
	case .SHA256RNDS2:
		info.access = {.Def, .Use, .Use, .Use}
		info.two_address = true
	case .AESIMC:
		info.access = {.Def, .Use, .None, .None}
	case .AESKEYGENASSIST:
		info.access = {.Def, .Use, .None, .None}
	case .CMP, .TEST, .UCOMISS, .UCOMISD:
		info.access = {.Use, .Use, .None, .None}
		info.writes_flags = true
	case .SETE, .SETNE, .SETL, .SETLE, .SETG, .SETGE, .SETB, .SETBE, .SETA, .SETAE, .SETP, .SETNP:
		info.access = {.Def, .None, .None, .None}
		info.reads_flags = true
	case .IDIV, .DIV, .MUL:
		info.access = {.Use, .None, .None, .None}
		info.writes_flags = true
	case .CMPXCHG, .XADD:
		info.writes_flags = true
	case .MFENCE, .XCHG, .PREFETCHT0, .PREFETCHT1, .PREFETCHT2, .PREFETCHNTA:
	case .CQO, .CDQ, .MOVSB, .STOSB, .STD, .CLD, .PAUSE, .INT3:
	case .CPUID, .XGETBV, .RDTSC:
	case .SYSCALL:
		info.writes_flags = true
	case .JE, .JNE, .JL, .JLE, .JG, .JGE, .JB, .JBE, .JA, .JAE, .JP, .JNP:
		info.reads_flags = true
		info.branch = true
	case .JMP:
		info.branch = true
		info.terminator = true
	case .UD2, .RET:
		info.terminator = true
	case:
		return {}, false
	}
	return info, true
}

// The one-operand IMUL (RDX:RAX = RAX * r/m) reads its only explicit operand, as MUL does; the
// two- and three-operand IMUL forms write their first operand.
instruction_info :: proc(instruction: Machine_Instruction) -> (info: Op_Info, known: bool) {
	if instruction.mnemonic == .IMUL && instruction.explicit_count == 1 {
		return op_info(.MUL)
	}
	return op_info(instruction.mnemonic)
}

package x64

// Reg is an x86-64 register together with its operand width.
//
// The value is a bit field so that the register number, class and width are
// recovered without a lookup table:
//
//	bits [3:0]  register number 0..15
//	bit  [4]    1 for an XMM (vector) register, 0 for a general-purpose one
//	bits [6:5]  width code: 0 = 8-bit, 1 = 16-bit, 2 = 32-bit, 3 = 64-bit
//	bit  [7]    valid flag, set for every real register, clear for REG_NONE
//
// The valid flag keeps the zero value inert: REG_NONE is Reg(0), so a
// zero-initialised operand names no register.
Reg :: distinct u8

// REG_NONE is the absent-register sentinel and the zero value of Reg.
REG_NONE :: Reg(0)

// Register class: general-purpose or XMM (SSE vector).
Reg_Class :: enum u8 {
	General,
	Vector,
}

// Reg_Width is a general-purpose operand size in bits.
Reg_Width :: enum u8 {
	Byte  = 8,
	Word  = 16,
	Dword = 32,
	Qword = 64,
}

// Base values pack a register class and width into the high bits of a Reg.
@(private)
REG_GPR8 :: 0x80

@(private)
REG_XMM :: 0x90

@(private)
REG_GPR16 :: 0xA0

@(private)
REG_GPR32 :: 0xC0

@(private)
REG_GPR64 :: 0xE0

// 8-bit general-purpose registers. SPL, BPL, SIL and DIL share numbers 4..7
// with the legacy high-byte registers and therefore require a REX prefix.
AL :: Reg(REG_GPR8 + 0x0)
CL :: Reg(REG_GPR8 + 0x1)
DL :: Reg(REG_GPR8 + 0x2)
BL :: Reg(REG_GPR8 + 0x3)
SPL :: Reg(REG_GPR8 + 0x4)
BPL :: Reg(REG_GPR8 + 0x5)
SIL :: Reg(REG_GPR8 + 0x6)
DIL :: Reg(REG_GPR8 + 0x7)
R8B :: Reg(REG_GPR8 + 0x8)
R9B :: Reg(REG_GPR8 + 0x9)
R10B :: Reg(REG_GPR8 + 0xA)
R11B :: Reg(REG_GPR8 + 0xB)
R12B :: Reg(REG_GPR8 + 0xC)
R13B :: Reg(REG_GPR8 + 0xD)
R14B :: Reg(REG_GPR8 + 0xE)
R15B :: Reg(REG_GPR8 + 0xF)

// 16-bit general-purpose registers.
AX :: Reg(REG_GPR16 + 0x0)
CX :: Reg(REG_GPR16 + 0x1)
DX :: Reg(REG_GPR16 + 0x2)
BX :: Reg(REG_GPR16 + 0x3)
SP :: Reg(REG_GPR16 + 0x4)
BP :: Reg(REG_GPR16 + 0x5)
SI :: Reg(REG_GPR16 + 0x6)
DI :: Reg(REG_GPR16 + 0x7)
R8W :: Reg(REG_GPR16 + 0x8)
R9W :: Reg(REG_GPR16 + 0x9)
R10W :: Reg(REG_GPR16 + 0xA)
R11W :: Reg(REG_GPR16 + 0xB)
R12W :: Reg(REG_GPR16 + 0xC)
R13W :: Reg(REG_GPR16 + 0xD)
R14W :: Reg(REG_GPR16 + 0xE)
R15W :: Reg(REG_GPR16 + 0xF)

// 32-bit general-purpose registers.
EAX :: Reg(REG_GPR32 + 0x0)
ECX :: Reg(REG_GPR32 + 0x1)
EDX :: Reg(REG_GPR32 + 0x2)
EBX :: Reg(REG_GPR32 + 0x3)
ESP :: Reg(REG_GPR32 + 0x4)
EBP :: Reg(REG_GPR32 + 0x5)
ESI :: Reg(REG_GPR32 + 0x6)
EDI :: Reg(REG_GPR32 + 0x7)
R8D :: Reg(REG_GPR32 + 0x8)
R9D :: Reg(REG_GPR32 + 0x9)
R10D :: Reg(REG_GPR32 + 0xA)
R11D :: Reg(REG_GPR32 + 0xB)
R12D :: Reg(REG_GPR32 + 0xC)
R13D :: Reg(REG_GPR32 + 0xD)
R14D :: Reg(REG_GPR32 + 0xE)
R15D :: Reg(REG_GPR32 + 0xF)

// 64-bit general-purpose registers.
RAX :: Reg(REG_GPR64 + 0x0)
RCX :: Reg(REG_GPR64 + 0x1)
RDX :: Reg(REG_GPR64 + 0x2)
RBX :: Reg(REG_GPR64 + 0x3)
RSP :: Reg(REG_GPR64 + 0x4)
RBP :: Reg(REG_GPR64 + 0x5)
RSI :: Reg(REG_GPR64 + 0x6)
RDI :: Reg(REG_GPR64 + 0x7)
R8 :: Reg(REG_GPR64 + 0x8)
R9 :: Reg(REG_GPR64 + 0x9)
R10 :: Reg(REG_GPR64 + 0xA)
R11 :: Reg(REG_GPR64 + 0xB)
R12 :: Reg(REG_GPR64 + 0xC)
R13 :: Reg(REG_GPR64 + 0xD)
R14 :: Reg(REG_GPR64 + 0xE)
R15 :: Reg(REG_GPR64 + 0xF)

// XMM registers, used by the SSE2 scalar instructions. An XMM register has no
// operand width of its own; the mnemonic fixes it.
XMM0 :: Reg(REG_XMM + 0x0)
XMM1 :: Reg(REG_XMM + 0x1)
XMM2 :: Reg(REG_XMM + 0x2)
XMM3 :: Reg(REG_XMM + 0x3)
XMM4 :: Reg(REG_XMM + 0x4)
XMM5 :: Reg(REG_XMM + 0x5)
XMM6 :: Reg(REG_XMM + 0x6)
XMM7 :: Reg(REG_XMM + 0x7)
XMM8 :: Reg(REG_XMM + 0x8)
XMM9 :: Reg(REG_XMM + 0x9)
XMM10 :: Reg(REG_XMM + 0xA)
XMM11 :: Reg(REG_XMM + 0xB)
XMM12 :: Reg(REG_XMM + 0xC)
XMM13 :: Reg(REG_XMM + 0xD)
XMM14 :: Reg(REG_XMM + 0xE)
XMM15 :: Reg(REG_XMM + 0xF)

// reg_valid reports whether r names a real register rather than REG_NONE.
reg_valid :: proc(r: Reg) -> bool {
	return (u8(r) & 0x80) != 0
}

// reg_index returns the 0..15 register number used in ModRM and SIB fields.
reg_index :: proc(r: Reg) -> u8 {
	return u8(r) & 0x0F
}

// reg_class returns the register class of r.
reg_class :: proc(r: Reg) -> Reg_Class {
	if (u8(r) & 0x10) != 0 {
		return .Vector
	}
	return .General
}

// reg_width returns the operand width of a general-purpose register r. The
// width is only meaningful for GPRs; for an XMM register it returns .Byte.
reg_width :: proc(r: Reg) -> Reg_Width {
	w := u8(8)
	return Reg_Width(w << ((u8(r) >> 5) & 0x3))
}

// Mem_Flag marks a property of a memory operand.
Mem_Flag :: enum u8 {
	// Rip_Relative selects RIP-relative addressing. base and index must be
	// REG_NONE; disp is the displacement from the next instruction.
	Rip_Relative,
	// Relocation marks disp as a symbol offset to be fixed up by a later
	// relocation pass. The encoder emits disp verbatim and does not act on it.
	Relocation,
}

// Mem_Flags is a set of Mem_Flag.
Mem_Flags :: bit_set[Mem_Flag; u8]

// Mem is a memory operand: base + index*scale + disp, or RIP-relative.
//
// base and index are 64-bit general-purpose registers or REG_NONE. RSP cannot
// be an index; R12 can. scale is 1, 2, 4 or 8 and is used only when index is
// present. The zero value addresses [0]. The width of a memory operand comes
// from the instruction it appears in, not from Mem itself.
Mem :: struct {
	base:  Reg,
	index: Reg,
	scale: u8,
	disp:  i32,
	flags: Mem_Flags,
}

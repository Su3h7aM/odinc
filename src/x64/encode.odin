package x64

import "core:mem"

// Encoding a machine-code instruction has three moving parts: the REX prefix,
// the ModRM/SIB addressing bytes, and the instruction's own opcode. The
// helpers below build each part; the instruction procedures at the bottom of
// the file compose them.
//
// All operands are validated with asserts. A caller that reaches this package
// through the backend's instruction selection is assumed to supply well-formed
// operands, so ill-formed input is a programming error, not a runtime error to
// be returned.

// Condition is an x86 condition code, shared by setcc, cmovcc and jcc.
Condition :: enum u8 {
	Overflow         = 0,
	Not_Overflow     = 1,
	Below            = 2,
	Above_Or_Equal    = 3,
	Equal            = 4,
	Not_Equal        = 5,
	Below_Or_Equal    = 6,
	Above            = 7,
	Sign             = 8,
	Not_Sign         = 9,
	Parity           = 10,
	Not_Parity       = 11,
	Less             = 12,
	Greater_Or_Equal = 13,
	Less_Or_Equal    = 14,
	Greater          = 15,
}

// Label identifies a branch target within one Emitter. LABEL_NONE is invalid.
Label :: distinct u32

// LABEL_NONE is the invalid label and the zero value of Label.
LABEL_NONE :: Label(0)

// Emitter appends encoded bytes to a byte buffer that it owns. Create it with
// emitter_init and release it with emitter_destroy. The buffer's allocator is
// supplied at init time.
Emitter :: struct {
	code:   [dynamic]byte,
	labels: [dynamic]Label_State,
	fixups: [dynamic]Fixup,
}

// Label_State is the binding record behind a Label.
@(private)
Label_State :: struct {
	bound:  bool,
	offset: int,
}

// Fixup records the position of a rel32 field awaiting label_resolve.
@(private)
Fixup :: struct {
	at:    int,
	label: Label,
}

// emitter_init creates the Emitter's buffers using allocator. The Emitter must
// be zero-valued on entry and must be released with emitter_destroy.
emitter_init :: proc(e: ^Emitter, allocator := context.allocator) -> (res: ^Emitter, err: mem.Allocator_Error) #optional_allocator_error {
	assert(e.code == nil, "Emitter is already initialised")
	e.code   = make([dynamic]byte, allocator) or_return
	e.labels = make([dynamic]Label_State, allocator) or_return
	e.fixups = make([dynamic]Fixup, allocator) or_return
	return e, .None
}

// emitter_destroy frees every buffer the Emitter owns and returns it to its
// zero value. Destroying a zero Emitter is a no-op.
emitter_destroy :: proc(e: ^Emitter) {
	delete(e.code)
	delete(e.labels)
	delete(e.fixups)
	e^ = {}
}

// emitter_reset clears the encoding state while keeping the allocated
// capacity and allocator. Labels created before the call become invalid.
emitter_reset :: proc(e: ^Emitter) {
	clear(&e.code)
	clear(&e.labels)
	clear(&e.fixups)
}

// emitter_bytes returns a view of the bytes emitted so far. The view is
// invalidated by the next append.
emitter_bytes :: proc(e: ^Emitter) -> []byte {
	return e.code[:]
}

// label_new allocates a fresh, unbound label.
label_new :: proc(e: ^Emitter) -> Label {
	append(&e.labels, Label_State{})
	return Label(len(e.labels))
}

// label_bind binds l to the current output position. A label may be bound once.
label_bind :: proc(e: ^Emitter, l: Label) {
	assert(l != LABEL_NONE, "cannot bind LABEL_NONE")
	idx := int(l) - 1
	assert(idx >= 0 && idx < len(e.labels), "unknown label")
	assert(!e.labels[idx].bound, "label bound more than once")
	e.labels[idx].bound = true
	e.labels[idx].offset = len(e.code)
}

// label_offset reports the position l is bound to. ok is false when l is
// LABEL_NONE, unknown, or not yet bound.
label_offset :: proc(e: ^Emitter, l: Label) -> (offset: int, ok: bool) {
	if l == LABEL_NONE {
		return 0, false
	}
	idx := int(l) - 1
	if idx < 0 || idx >= len(e.labels) {
		return 0, false
	}
	st := e.labels[idx]
	if !st.bound {
		return 0, false
	}
	return st.offset, true
}

// label_use reserves a 32-bit PC-relative field at the current output position
// and records a fixup against l. The four bytes that follow belong to the
// field; emit the opcode before calling this.
label_use :: proc(e: ^Emitter, l: Label) {
	assert(l != LABEL_NONE, "cannot reference LABEL_NONE")
	append(&e.fixups, Fixup{at = len(e.code), label = l})
	emit_u32(e, 0)
}

// label_resolve back-patches every recorded rel32 field against its label,
// which must be bound. It is idempotent while no further bytes are emitted.
label_resolve :: proc(e: ^Emitter) {
	for f in e.fixups {
		st := e.labels[int(f.label) - 1]
		assert(st.bound, "unbound label referenced by a fixup")
		rel := i64(st.offset) - i64(f.at + 4)
		assert(rel >= -2147483648 && rel <= 2147483647, "rel32 displacement out of range")
		v := u32(i32(rel))
		e.code[f.at + 0] = byte(v)
		e.code[f.at + 1] = byte(v >> 8)
		e.code[f.at + 2] = byte(v >> 16)
		e.code[f.at + 3] = byte(v >> 24)
	}
}

// ----------------------------------------------------------------------------
// byte output
// ----------------------------------------------------------------------------

@(private)
emit_byte :: proc(e: ^Emitter, b: byte) {
	append(&e.code, b)
}

@(private)
emit_u16 :: proc(e: ^Emitter, v: u16) {
	append(&e.code, byte(v), byte(v >> 8))
}

@(private)
emit_u32 :: proc(e: ^Emitter, v: u32) {
	append(&e.code, byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24))
}

@(private)
emit_u64 :: proc(e: ^Emitter, v: u64) {
	append(
		&e.code,
		byte(v),
		byte(v >> 8),
		byte(v >> 16),
		byte(v >> 24),
		byte(v >> 32),
		byte(v >> 40),
		byte(v >> 48),
		byte(v >> 56),
	)
}

// ----------------------------------------------------------------------------
// operand validation
// ----------------------------------------------------------------------------

@(private)
assert_gpr :: proc(r: Reg) {
	assert(reg_valid(r) && reg_class(r) == .General, "expected a general-purpose register")
}

@(private)
assert_xmm :: proc(r: Reg) {
	assert(reg_valid(r) && reg_class(r) == .Vector, "expected an XMM register")
}

@(private)
imm_fits :: proc(imm: i64, width: Reg_Width) -> bool {
	switch width {
	case .Byte:
		return imm >= -128 && imm <= 255
	case .Word:
		return imm >= -32768 && imm <= 65535
	case .Dword:
		return imm >= -2147483648 && imm <= 4294967295
	case .Qword:
		return true
	}
	return false
}

// ----------------------------------------------------------------------------
// REX, ModRM and SIB
// ----------------------------------------------------------------------------

@(private)
Rex_Bit :: enum u8 {
	W,
	R,
	X,
	B,
}

@(private)
Rex :: bit_set[Rex_Bit; u8]

@(private)
rex_emit :: proc(e: ^Emitter, rex: Rex, force: bool) {
	if !force && .W not_in rex && .R not_in rex && .X not_in rex && .B not_in rex {
		return
	}
	b: u8 = 0x40
	if .W in rex {
		b |= 0x08
	}
	if .R in rex {
		b |= 0x04
	}
	if .X in rex {
		b |= 0x02
	}
	if .B in rex {
		b |= 0x01
	}
	emit_byte(e, b)
}

// Insn is the REX-independent part of a ModRM instruction.
@(private)
Insn :: struct {
	prefix:    byte, // mandatory prefix byte (0x66, 0xF2 or 0xF3), or 0
	opcode:    u8,
	two_byte:  bool, // emit the 0x0F escape before opcode
	rex_w:     bool,
	force_rex: bool, // force a REX prefix when no REX bit is set (spl/bpl/sil/dil)
}

// Rm_Mem is the ModRM (and SIB, and displacement) tail of a memory operand.
@(private)
Rm_Mem :: struct {
	bytes: [6]byte,
	count: int,
	rex_x: bool,
	rex_b: bool,
}

@(private)
append_disp :: proc(out: ^Rm_Mem, d: i32, n: int) {
	switch n {
	case 1:
		out.bytes[out.count] = byte(d)
		out.count += 1
	case 4:
		v := u32(d)
		out.bytes[out.count + 0] = byte(v)
		out.bytes[out.count + 1] = byte(v >> 8)
		out.bytes[out.count + 2] = byte(v >> 16)
		out.bytes[out.count + 3] = byte(v >> 24)
		out.count += 4
	case:
		panic("invalid displacement size")
	}
}

// encode_mem builds the ModRM/SIB/displacement bytes for a memory operand and
// reports the index (X) and base (B) REX bits it needs.
@(private)
encode_mem :: proc(reg_field: u8, mem: Mem) -> Rm_Mem {
	out: Rm_Mem
	rf := reg_field & 0x7
	has_base := mem.base != REG_NONE
	has_index := mem.index != REG_NONE

	if .Rip_Relative in mem.flags {
		assert(!has_base && !has_index, "RIP-relative operand must not have a base or index")
		out.bytes[0] = (0 << 6) | (rf << 3) | 0x5
		out.count = 1
		append_disp(&out, mem.disp, 4)
		return out
	}

	if !has_base && !has_index {
		// Absolute [disp32]: ModRM.rm = 100 (SIB), SIB.base = 101 (none).
		out.bytes[0] = (0 << 6) | (rf << 3) | 0x4
		out.bytes[1] = (0 << 6) | (0x4 << 3) | 0x5
		out.count = 2
		append_disp(&out, mem.disp, 4)
		return out
	}

	if has_index {
		assert(mem.scale == 1 || mem.scale == 2 || mem.scale == 4 || mem.scale == 8, "invalid SIB scale")
		assert(reg_index(mem.index) != 0x4, "RSP cannot be an index register")
	}

	base_low := u8(0)
	use_sib := has_index
	if has_base {
		base_low = reg_index(mem.base) & 0x7
		if base_low == 0x4 { // RSP/R12 as a base always require a SIB byte
			use_sib = true
		}
	}

	if use_sib {
		base_none := !has_base
		mod: u8
		switch {
		case base_none:
			mod = 0
		case mem.disp == 0 && base_low != 0x5:
			mod = 0
		case mem.disp >= -128 && mem.disp <= 127:
			mod = 1
		case:
			mod = 2
		}
		out.bytes[0] = (mod << 6) | (rf << 3) | 0x4

		scale_bits: u8
		switch mem.scale {
		case 1:
			scale_bits = 0
		case 2:
			scale_bits = 1
		case 4:
			scale_bits = 2
		case 8:
			scale_bits = 3
		case:
			scale_bits = 0
		}
		index_bits: u8 = 0x4
		if has_index {
			index_bits = reg_index(mem.index) & 0x7
		}
		base_bits: u8 = base_none ? 0x5 : base_low
		out.bytes[1] = (scale_bits << 6) | (index_bits << 3) | base_bits
		out.count = 2
		if mod == 1 {
			append_disp(&out, mem.disp, 1)
		} else if mod == 2 || base_none {
			append_disp(&out, mem.disp, 4)
		}
		out.rex_x = has_index && reg_index(mem.index) >= 8
		out.rex_b = has_base && reg_index(mem.base) >= 8
	} else {
		mod: u8
		switch {
		case mem.disp == 0 && base_low != 0x5:
			mod = 0
		case mem.disp >= -128 && mem.disp <= 127:
			mod = 1
		case:
			mod = 2
		}
		out.bytes[0] = (mod << 6) | (rf << 3) | base_low
		out.count = 1
		if mod == 1 {
			append_disp(&out, mem.disp, 1)
		} else if mod == 2 {
			append_disp(&out, mem.disp, 4)
		}
		out.rex_b = reg_index(mem.base) >= 8
	}
	return out
}

@(private)
emit_operand_size :: proc(e: ^Emitter, width: Reg_Width) {
	if width == .Word {
		emit_byte(e, 0x66)
	}
}

@(private)
emit_reg_reg :: proc(e: ^Emitter, insn: Insn, reg_field, rm_reg: u8, width: Reg_Width) {
	emit_operand_size(e, width)
	if insn.prefix != 0 {
		emit_byte(e, insn.prefix)
	}
	rex := Rex{}
	if insn.rex_w {
		rex |= {.W}
	}
	if reg_field >= 8 {
		rex |= {.R}
	}
	if rm_reg >= 8 {
		rex |= {.B}
	}
	rex_emit(e, rex, insn.force_rex)
	if insn.two_byte {
		emit_byte(e, 0x0F)
	}
	emit_byte(e, insn.opcode)
	emit_byte(e, 0xC0 | ((reg_field & 0x7) << 3) | (rm_reg & 0x7))
}

@(private)
emit_reg_mem :: proc(e: ^Emitter, insn: Insn, reg_field: u8, mem: Mem, width: Reg_Width) {
	emit_operand_size(e, width)
	if insn.prefix != 0 {
		emit_byte(e, insn.prefix)
	}
	rm := encode_mem(reg_field, mem)
	rex := Rex{}
	if insn.rex_w {
		rex |= {.W}
	}
	if reg_field >= 8 {
		rex |= {.R}
	}
	if rm.rex_x {
		rex |= {.X}
	}
	if rm.rex_b {
		rex |= {.B}
	}
	rex_emit(e, rex, insn.force_rex)
	if insn.two_byte {
		emit_byte(e, 0x0F)
	}
	emit_byte(e, insn.opcode)
	for i in 0 ..< rm.count {
		emit_byte(e, rm.bytes[i])
	}
}

// emit_op_plus_reg emits an opcode whose low three bits carry the register
// number (B0+rb, B8+rd, 50+rd, 58+rd).
@(private)
emit_op_plus_reg :: proc(e: ^Emitter, opcode_base: u8, r: u8, rex_w, force_rex: bool) {
	rex := Rex{}
	if rex_w {
		rex |= {.W}
	}
	if r >= 8 {
		rex |= {.B}
	}
	rex_emit(e, rex, force_rex)
	emit_byte(e, opcode_base + (r & 0x7))
}

// ----------------------------------------------------------------------------
// mov
// ----------------------------------------------------------------------------

// mov_reg_reg encodes `mov dst, src` for two GPRs of equal width.
mov_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	w := reg_width(dst)
	assert(reg_width(src) == w, "operand width mismatch")
	byte_form := w == .Byte
	force := byte_form && (reg_index(src) >= 4 || reg_index(dst) >= 4)
	emit_reg_reg(e, Insn{opcode = byte_form ? 0x88 : 0x89, rex_w = w == .Qword, force_rex = force}, reg_index(src), reg_index(dst), w)
}

// mov_reg_mem encodes `mov dst, src` from memory to a GPR.
mov_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	w := reg_width(dst)
	byte_form := w == .Byte
	force := byte_form && reg_index(dst) >= 4
	emit_reg_mem(e, Insn{opcode = byte_form ? 0x8A : 0x8B, rex_w = w == .Qword, force_rex = force}, reg_index(dst), src, w)
}

// mov_mem_reg encodes `mov dst, src` from a GPR to memory.
mov_mem_reg :: proc(e: ^Emitter, dst: Mem, src: Reg) {
	assert_gpr(src)
	w := reg_width(src)
	byte_form := w == .Byte
	force := byte_form && reg_index(src) >= 4
	emit_reg_mem(e, Insn{opcode = byte_form ? 0x88 : 0x89, rex_w = w == .Qword, force_rex = force}, reg_index(src), dst, w)
}

// mov_reg_imm encodes `mov dst, imm`. For a 64-bit destination it uses the
// sign-extended 32-bit form when imm fits, and the 64-bit form otherwise.
mov_reg_imm :: proc(e: ^Emitter, dst: Reg, imm: i64) {
	assert_gpr(dst)
	w := reg_width(dst)
	switch w {
	case .Byte:
		assert(imm_fits(imm, .Byte), "immediate out of range")
		emit_op_plus_reg(e, 0xB0, reg_index(dst), false, reg_index(dst) >= 4)
		emit_byte(e, byte(imm))
	case .Word:
		assert(imm_fits(imm, .Word), "immediate out of range")
		emit_byte(e, 0x66)
		emit_op_plus_reg(e, 0xB8, reg_index(dst), false, false)
		emit_u16(e, u16(imm))
	case .Dword:
		assert(imm_fits(imm, .Dword), "immediate out of range")
		emit_op_plus_reg(e, 0xB8, reg_index(dst), false, false)
		emit_u32(e, u32(imm))
	case .Qword:
		if imm >= -2147483648 && imm <= 2147483647 {
			emit_reg_reg(e, Insn{opcode = 0xC7, rex_w = true}, 0, reg_index(dst), .Qword)
			emit_u32(e, u32(i32(imm)))
		} else {
			movabs_reg_imm64(e, dst, imm)
		}
	}
}

// movabs_reg_imm64 encodes the 64-bit `movabs dst, imm` form. dst must be a
// 64-bit GPR.
movabs_reg_imm64 :: proc(e: ^Emitter, dst: Reg, imm: i64) {
	assert_gpr(dst)
	assert(reg_width(dst) == .Qword, "movabs destination must be 64-bit")
	emit_op_plus_reg(e, 0xB8, reg_index(dst), true, false)
	emit_u64(e, u64(imm))
}

// ----------------------------------------------------------------------------
// movzx / movsx / movsxd
// ----------------------------------------------------------------------------

// movzx_reg_reg encodes `movzx dst, src` widening an 8/16-bit GPR.
movzx_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	dw := reg_width(dst)
	sw := reg_width(src)
	assert(dw == .Word || dw == .Dword || dw == .Qword, "movzx destination must be 16, 32 or 64-bit")
	assert(sw == .Byte || sw == .Word, "movzx source must be 8 or 16-bit")
	opcode: u8 = sw == .Byte ? 0xB6 : 0xB7
	emit_reg_reg(e, Insn{opcode = opcode, two_byte = true, rex_w = dw == .Qword}, reg_index(dst), reg_index(src), dw)
}

// movzx_reg_mem encodes `movzx dst, src` from memory; src_width names the
// memory operand's size (Byte or Word).
movzx_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem, src_width: Reg_Width) {
	assert_gpr(dst)
	dw := reg_width(dst)
	assert(dw == .Word || dw == .Dword || dw == .Qword, "movzx destination must be 16, 32 or 64-bit")
	assert(src_width == .Byte || src_width == .Word, "movzx source must be 8 or 16-bit")
	opcode: u8 = src_width == .Byte ? 0xB6 : 0xB7
	emit_reg_mem(e, Insn{opcode = opcode, two_byte = true, rex_w = dw == .Qword}, reg_index(dst), src, dw)
}

// movsx_reg_reg encodes `movsx dst, src` widening an 8/16-bit GPR.
movsx_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	dw := reg_width(dst)
	sw := reg_width(src)
	assert(dw == .Word || dw == .Dword || dw == .Qword, "movsx destination must be 16, 32 or 64-bit")
	assert(sw == .Byte || sw == .Word, "movsx source must be 8 or 16-bit")
	opcode: u8 = sw == .Byte ? 0xBE : 0xBF
	emit_reg_reg(e, Insn{opcode = opcode, two_byte = true, rex_w = dw == .Qword}, reg_index(dst), reg_index(src), dw)
}

// movsx_reg_mem encodes `movsx dst, src` from memory; src_width names the
// memory operand's size (Byte or Word).
movsx_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem, src_width: Reg_Width) {
	assert_gpr(dst)
	dw := reg_width(dst)
	assert(dw == .Word || dw == .Dword || dw == .Qword, "movsx destination must be 16, 32 or 64-bit")
	assert(src_width == .Byte || src_width == .Word, "movsx source must be 8 or 16-bit")
	opcode: u8 = src_width == .Byte ? 0xBE : 0xBF
	emit_reg_mem(e, Insn{opcode = opcode, two_byte = true, rex_w = dw == .Qword}, reg_index(dst), src, dw)
}

// movsxd_reg_reg encodes `movsxd dst, src` widening a 32-bit GPR to 64 bits.
movsxd_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	assert(reg_width(dst) == .Qword, "movsxd destination must be 64-bit")
	assert(reg_width(src) == .Dword, "movsxd source must be 32-bit")
	emit_reg_reg(e, Insn{opcode = 0x63, rex_w = true}, reg_index(dst), reg_index(src), .Dword)
}

// movsxd_reg_mem encodes `movsxd dst, src` from a 32-bit memory operand.
movsxd_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	assert(reg_width(dst) == .Qword, "movsxd destination must be 64-bit")
	emit_reg_mem(e, Insn{opcode = 0x63, rex_w = true}, reg_index(dst), src, .Dword)
}

// ----------------------------------------------------------------------------
// lea
// ----------------------------------------------------------------------------

// lea_reg_mem encodes `lea dst, src` computing the address of src.
lea_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	w := reg_width(dst)
	assert(w != .Byte, "lea has no 8-bit form")
	emit_reg_mem(e, Insn{opcode = 0x8D, rex_w = w == .Qword}, reg_index(dst), src, w)
}

// ----------------------------------------------------------------------------
// add / sub / and / or / xor / cmp
// ----------------------------------------------------------------------------

@(private)
Alu_Op :: enum u8 {
	Add = 0,
	Or  = 1,
	And = 4,
	Sub = 5,
	Xor = 6,
	Cmp = 7,
}

@(private)
alu_reg_reg :: proc(e: ^Emitter, op: Alu_Op, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	w := reg_width(dst)
	assert(reg_width(src) == w, "operand width mismatch")
	byte_form := w == .Byte
	base := u8(op) * 8
	if !byte_form {
		base += 1
	}
	force := byte_form && (reg_index(src) >= 4 || reg_index(dst) >= 4)
	emit_reg_reg(e, Insn{opcode = base, rex_w = w == .Qword, force_rex = force}, reg_index(src), reg_index(dst), w)
}

@(private)
alu_reg_mem :: proc(e: ^Emitter, op: Alu_Op, dst: Reg, src: Mem) {
	assert_gpr(dst)
	w := reg_width(dst)
	byte_form := w == .Byte
	base := u8(op) * 8 + 2
	if !byte_form {
		base += 1
	}
	force := byte_form && reg_index(dst) >= 4
	emit_reg_mem(e, Insn{opcode = base, rex_w = w == .Qword, force_rex = force}, reg_index(dst), src, w)
}

@(private)
alu_mem_reg :: proc(e: ^Emitter, op: Alu_Op, dst: Mem, src: Reg) {
	assert_gpr(src)
	w := reg_width(src)
	byte_form := w == .Byte
	base := u8(op) * 8
	if !byte_form {
		base += 1
	}
	force := byte_form && reg_index(src) >= 4
	emit_reg_mem(e, Insn{opcode = base, rex_w = w == .Qword, force_rex = force}, reg_index(src), dst, w)
}

@(private)
alu_reg_imm :: proc(e: ^Emitter, op: Alu_Op, dst: Reg, imm: i64) {
	assert_gpr(dst)
	w := reg_width(dst)
	if w == .Byte {
		assert(imm_fits(imm, .Byte), "immediate out of range")
		force := reg_index(dst) >= 4
		emit_reg_reg(e, Insn{opcode = 0x80, rex_w = w == .Qword, force_rex = force}, u8(op), reg_index(dst), .Byte)
		emit_byte(e, byte(imm))
		return
	}
	if imm >= -128 && imm <= 127 {
		emit_reg_reg(e, Insn{opcode = 0x83, rex_w = w == .Qword}, u8(op), reg_index(dst), w)
		emit_byte(e, byte(imm))
		return
	}
	switch w {
	case .Word:
		assert(imm >= -32768 && imm <= 65535, "immediate out of range")
		emit_reg_reg(e, Insn{opcode = 0x81, rex_w = w == .Qword}, u8(op), reg_index(dst), w)
		emit_u16(e, u16(imm))
	case .Dword:
		assert(imm >= -2147483648 && imm <= 4294967295, "immediate out of range")
		emit_reg_reg(e, Insn{opcode = 0x81, rex_w = w == .Qword}, u8(op), reg_index(dst), w)
		emit_u32(e, u32(imm))
	case .Qword:
		assert(imm >= -2147483648 && imm <= 2147483647, "immediate does not fit the sign-extended 32-bit form")
		emit_reg_reg(e, Insn{opcode = 0x81, rex_w = w == .Qword}, u8(op), reg_index(dst), w)
		emit_u32(e, u32(i32(imm)))
	case .Byte:
		return
	}
}

// add_reg_reg encodes `add dst, src` for two GPRs of equal width.
add_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {alu_reg_reg(e, .Add, dst, src)}

// add_reg_mem encodes `add dst, src` from memory to a GPR.
add_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(e, .Add, dst, src)}

// add_mem_reg encodes `add dst, src` from a GPR to memory.
add_mem_reg :: proc(e: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(e, .Add, dst, src)}

// add_reg_imm encodes `add dst, imm`.
add_reg_imm :: proc(e: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(e, .Add, dst, imm)}

// sub_reg_reg encodes `sub dst, src` for two GPRs of equal width.
sub_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {alu_reg_reg(e, .Sub, dst, src)}

// sub_reg_mem encodes `sub dst, src` from memory to a GPR.
sub_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(e, .Sub, dst, src)}

// sub_mem_reg encodes `sub dst, src` from a GPR to memory.
sub_mem_reg :: proc(e: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(e, .Sub, dst, src)}

// sub_reg_imm encodes `sub dst, imm`.
sub_reg_imm :: proc(e: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(e, .Sub, dst, imm)}

// and_reg_reg encodes `and dst, src` for two GPRs of equal width.
and_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {alu_reg_reg(e, .And, dst, src)}

// and_reg_mem encodes `and dst, src` from memory to a GPR.
and_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(e, .And, dst, src)}

// and_mem_reg encodes `and dst, src` from a GPR to memory.
and_mem_reg :: proc(e: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(e, .And, dst, src)}

// and_reg_imm encodes `and dst, imm`.
and_reg_imm :: proc(e: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(e, .And, dst, imm)}

// or_reg_reg encodes `or dst, src` for two GPRs of equal width.
or_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {alu_reg_reg(e, .Or, dst, src)}

// or_reg_mem encodes `or dst, src` from memory to a GPR.
or_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(e, .Or, dst, src)}

// or_mem_reg encodes `or dst, src` from a GPR to memory.
or_mem_reg :: proc(e: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(e, .Or, dst, src)}

// or_reg_imm encodes `or dst, imm`.
or_reg_imm :: proc(e: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(e, .Or, dst, imm)}

// xor_reg_reg encodes `xor dst, src` for two GPRs of equal width.
xor_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {alu_reg_reg(e, .Xor, dst, src)}

// xor_reg_mem encodes `xor dst, src` from memory to a GPR.
xor_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(e, .Xor, dst, src)}

// xor_mem_reg encodes `xor dst, src` from a GPR to memory.
xor_mem_reg :: proc(e: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(e, .Xor, dst, src)}

// xor_reg_imm encodes `xor dst, imm`.
xor_reg_imm :: proc(e: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(e, .Xor, dst, imm)}

// cmp_reg_reg encodes `cmp dst, src` for two GPRs of equal width.
cmp_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {alu_reg_reg(e, .Cmp, dst, src)}

// cmp_reg_mem encodes `cmp dst, src` from memory to a GPR.
cmp_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(e, .Cmp, dst, src)}

// cmp_mem_reg encodes `cmp dst, src` from a GPR to memory.
cmp_mem_reg :: proc(e: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(e, .Cmp, dst, src)}

// cmp_reg_imm encodes `cmp dst, imm`.
cmp_reg_imm :: proc(e: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(e, .Cmp, dst, imm)}

// ----------------------------------------------------------------------------
// test
// ----------------------------------------------------------------------------

@(private)
test_rr :: proc(e: ^Emitter, a, b: Reg) {
	assert_gpr(a)
	assert_gpr(b)
	w := reg_width(a)
	assert(reg_width(b) == w, "operand width mismatch")
	byte_form := w == .Byte
	force := byte_form && (reg_index(a) >= 4 || reg_index(b) >= 4)
	emit_reg_reg(e, Insn{opcode = byte_form ? 0x84 : 0x85, rex_w = w == .Qword, force_rex = force}, reg_index(b), reg_index(a), w)
}

@(private)
test_rm :: proc(e: ^Emitter, reg: Reg, mem: Mem) {
	assert_gpr(reg)
	w := reg_width(reg)
	byte_form := w == .Byte
	force := byte_form && reg_index(reg) >= 4
	emit_reg_mem(e, Insn{opcode = byte_form ? 0x84 : 0x85, rex_w = w == .Qword, force_rex = force}, reg_index(reg), mem, w)
}

// test_reg_reg encodes `test a, b` for two GPRs of equal width.
test_reg_reg :: proc(e: ^Emitter, a, b: Reg) {test_rr(e, a, b)}

// test_reg_mem encodes `test reg, mem`.
test_reg_mem :: proc(e: ^Emitter, reg: Reg, mem: Mem) {test_rm(e, reg, mem)}

// test_mem_reg encodes `test mem, reg` (the instruction is symmetric).
test_mem_reg :: proc(e: ^Emitter, mem: Mem, reg: Reg) {test_rm(e, reg, mem)}

// test_reg_imm encodes `test reg, imm`.
test_reg_imm :: proc(e: ^Emitter, reg: Reg, imm: i64) {
	assert_gpr(reg)
	w := reg_width(reg)
	if w == .Byte {
		assert(imm_fits(imm, .Byte), "immediate out of range")
		force := reg_index(reg) >= 4
		emit_reg_reg(e, Insn{opcode = 0xF6, rex_w = w == .Qword, force_rex = force}, 0, reg_index(reg), .Byte)
		emit_byte(e, byte(imm))
		return
	}
	emit_reg_reg(e, Insn{opcode = 0xF7, rex_w = w == .Qword}, 0, reg_index(reg), w)
	switch w {
	case .Word:
		assert(imm >= -32768 && imm <= 65535, "immediate out of range")
		emit_u16(e, u16(imm))
	case .Dword:
		assert(imm >= -2147483648 && imm <= 4294967295, "immediate out of range")
		emit_u32(e, u32(imm))
	case .Qword:
		assert(imm >= -2147483648 && imm <= 2147483647, "immediate does not fit the sign-extended 32-bit form")
		emit_u32(e, u32(i32(imm)))
	case .Byte:
		return
	}
}

// ----------------------------------------------------------------------------
// imul / div / idiv / cqo / cdq / neg / not
// ----------------------------------------------------------------------------

// imul_reg_reg encodes the two-operand `imul dst, src`. There is no 8-bit form.
imul_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	w := reg_width(dst)
	assert(w != .Byte, "imul has no 8-bit two-operand form")
	assert(reg_width(src) == w, "operand width mismatch")
	emit_reg_reg(e, Insn{opcode = 0xAF, two_byte = true, rex_w = w == .Qword}, reg_index(dst), reg_index(src), w)
}

// imul_reg_mem encodes the two-operand `imul dst, src` from memory.
imul_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	w := reg_width(dst)
	assert(w != .Byte, "imul has no 8-bit two-operand form")
	emit_reg_mem(e, Insn{opcode = 0xAF, two_byte = true, rex_w = w == .Qword}, reg_index(dst), src, w)
}

// imul_reg_reg_imm encodes the three-operand `imul dst, src, imm`.
imul_reg_reg_imm :: proc(e: ^Emitter, dst, src: Reg, imm: i32) {
	assert_gpr(dst)
	assert_gpr(src)
	w := reg_width(dst)
	assert(w != .Byte, "imul has no 8-bit three-operand form")
	assert(reg_width(src) == w, "operand width mismatch")
	if imm >= -128 && imm <= 127 {
		emit_reg_reg(e, Insn{opcode = 0x6B, rex_w = w == .Qword}, reg_index(dst), reg_index(src), w)
		emit_byte(e, byte(imm))
		return
	}
	emit_reg_reg(e, Insn{opcode = 0x69, rex_w = w == .Qword}, reg_index(dst), reg_index(src), w)
	switch w {
	case .Word:
		emit_u16(e, u16(imm))
	case .Dword:
		emit_u32(e, u32(imm))
	case .Qword:
		emit_u32(e, u32(imm))
	case .Byte:
		return
	}
}

@(private)
group_f6_f7 :: proc(e: ^Emitter, digit: u8, reg: Reg) {
	assert_gpr(reg)
	w := reg_width(reg)
	byte_form := w == .Byte
	force := byte_form && reg_index(reg) >= 4
	emit_reg_reg(e, Insn{opcode = byte_form ? 0xF6 : 0xF7, rex_w = w == .Qword, force_rex = force}, digit, reg_index(reg), w)
}

@(private)
group_f6_f7_mem :: proc(e: ^Emitter, digit: u8, mem: Mem, width: Reg_Width) {
	emit_reg_mem(e, Insn{opcode = width == .Byte ? 0xF6 : 0xF7, rex_w = width == .Qword}, digit, mem, width)
}

// div_reg encodes the one-operand `div src`.
div_reg :: proc(e: ^Emitter, src: Reg) {group_f6_f7(e, 6, src)}

// div_mem encodes the one-operand `div src` from memory; width gives the
// operand size the memory operand is read at.
div_mem :: proc(e: ^Emitter, src: Mem, width: Reg_Width) {group_f6_f7_mem(e, 6, src, width)}

// idiv_reg encodes the one-operand `idiv src`.
idiv_reg :: proc(e: ^Emitter, src: Reg) {group_f6_f7(e, 7, src)}

// idiv_mem encodes the one-operand `idiv src` from memory; width gives the
// operand size the memory operand is read at.
idiv_mem :: proc(e: ^Emitter, src: Mem, width: Reg_Width) {group_f6_f7_mem(e, 7, src, width)}

// neg_reg encodes `neg dst`.
neg_reg :: proc(e: ^Emitter, dst: Reg) {group_f6_f7(e, 3, dst)}

// neg_mem encodes `neg dst` on memory; width gives the operand size.
neg_mem :: proc(e: ^Emitter, dst: Mem, width: Reg_Width) {group_f6_f7_mem(e, 3, dst, width)}

// not_reg encodes `not dst`.
not_reg :: proc(e: ^Emitter, dst: Reg) {group_f6_f7(e, 2, dst)}

// not_mem encodes `not dst` on memory; width gives the operand size.
not_mem :: proc(e: ^Emitter, dst: Mem, width: Reg_Width) {group_f6_f7_mem(e, 2, dst, width)}

// cqo sign-extends RAX into RDX:RAX.
cqo :: proc(e: ^Emitter) {
	emit_byte(e, 0x48)
	emit_byte(e, 0x99)
}

// cdq sign-extends EAX into EDX:EAX.
cdq :: proc(e: ^Emitter) {
	emit_byte(e, 0x99)
}

// ----------------------------------------------------------------------------
// shl / shr / sar
// ----------------------------------------------------------------------------

@(private)
shift_imm :: proc(e: ^Emitter, digit: u8, dst: Reg, imm: u8) {
	assert_gpr(dst)
	w := reg_width(dst)
	byte_form := w == .Byte
	force := byte_form && reg_index(dst) >= 4
	emit_reg_reg(e, Insn{opcode = byte_form ? 0xC0 : 0xC1, rex_w = w == .Qword, force_rex = force}, digit, reg_index(dst), w)
	emit_byte(e, imm)
}

@(private)
shift_cl :: proc(e: ^Emitter, digit: u8, dst: Reg) {
	assert_gpr(dst)
	w := reg_width(dst)
	byte_form := w == .Byte
	force := byte_form && reg_index(dst) >= 4
	emit_reg_reg(e, Insn{opcode = byte_form ? 0xD2 : 0xD3, rex_w = w == .Qword, force_rex = force}, digit, reg_index(dst), w)
}

@(private)
shift_imm_mem :: proc(e: ^Emitter, digit: u8, dst: Mem, imm: u8, width: Reg_Width) {
	emit_reg_mem(e, Insn{opcode = width == .Byte ? 0xC0 : 0xC1, rex_w = width == .Qword}, digit, dst, width)
	emit_byte(e, imm)
}

@(private)
shift_cl_mem :: proc(e: ^Emitter, digit: u8, dst: Mem, width: Reg_Width) {
	emit_reg_mem(e, Insn{opcode = width == .Byte ? 0xD2 : 0xD3, rex_w = width == .Qword}, digit, dst, width)
}

// shl_reg_imm encodes `shl dst, imm`.
shl_reg_imm :: proc(e: ^Emitter, dst: Reg, imm: u8) {shift_imm(e, 4, dst, imm)}

// shr_reg_imm encodes `shr dst, imm`.
shr_reg_imm :: proc(e: ^Emitter, dst: Reg, imm: u8) {shift_imm(e, 5, dst, imm)}

// sar_reg_imm encodes `sar dst, imm`.
sar_reg_imm :: proc(e: ^Emitter, dst: Reg, imm: u8) {shift_imm(e, 7, dst, imm)}

// shl_reg_cl encodes `shl dst, cl`.
shl_reg_cl :: proc(e: ^Emitter, dst: Reg) {shift_cl(e, 4, dst)}

// shr_reg_cl encodes `shr dst, cl`.
shr_reg_cl :: proc(e: ^Emitter, dst: Reg) {shift_cl(e, 5, dst)}

// sar_reg_cl encodes `sar dst, cl`.
sar_reg_cl :: proc(e: ^Emitter, dst: Reg) {shift_cl(e, 7, dst)}

// shl_mem_imm encodes `shl dst, imm` on memory; width gives the operand size.
shl_mem_imm :: proc(e: ^Emitter, dst: Mem, imm: u8, width: Reg_Width) {shift_imm_mem(e, 4, dst, imm, width)}

// shr_mem_imm encodes `shr dst, imm` on memory; width gives the operand size.
shr_mem_imm :: proc(e: ^Emitter, dst: Mem, imm: u8, width: Reg_Width) {shift_imm_mem(e, 5, dst, imm, width)}

// sar_mem_imm encodes `sar dst, imm` on memory; width gives the operand size.
sar_mem_imm :: proc(e: ^Emitter, dst: Mem, imm: u8, width: Reg_Width) {shift_imm_mem(e, 7, dst, imm, width)}

// shl_mem_cl encodes `shl dst, cl` on memory; width gives the operand size.
shl_mem_cl :: proc(e: ^Emitter, dst: Mem, width: Reg_Width) {shift_cl_mem(e, 4, dst, width)}

// shr_mem_cl encodes `shr dst, cl` on memory; width gives the operand size.
shr_mem_cl :: proc(e: ^Emitter, dst: Mem, width: Reg_Width) {shift_cl_mem(e, 5, dst, width)}

// sar_mem_cl encodes `sar dst, cl` on memory; width gives the operand size.
sar_mem_cl :: proc(e: ^Emitter, dst: Mem, width: Reg_Width) {shift_cl_mem(e, 7, dst, width)}

// ----------------------------------------------------------------------------
// setcc / cmovcc
// ----------------------------------------------------------------------------

// setcc_reg encodes `setcc dst`, writing an 8-bit GPR.
setcc_reg :: proc(e: ^Emitter, cond: Condition, dst: Reg) {
	assert_gpr(dst)
	assert(reg_width(dst) == .Byte, "setcc destination must be 8-bit")
	force := reg_index(dst) >= 4
	emit_reg_reg(e, Insn{opcode = 0x90 + u8(cond), two_byte = true, force_rex = force}, 0, reg_index(dst), .Byte)
}

// setcc_mem encodes `setcc dst`, writing a byte in memory.
setcc_mem :: proc(e: ^Emitter, cond: Condition, dst: Mem) {
	emit_reg_mem(e, Insn{opcode = 0x90 + u8(cond), two_byte = true}, 0, dst, .Byte)
}

// cmovcc_reg_reg encodes `cmovcc dst, src` for two GPRs of equal width.
cmovcc_reg_reg :: proc(e: ^Emitter, cond: Condition, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	w := reg_width(dst)
	assert(w != .Byte, "cmovcc has no 8-bit form")
	assert(reg_width(src) == w, "operand width mismatch")
	emit_reg_reg(e, Insn{opcode = 0x40 + u8(cond), two_byte = true, rex_w = w == .Qword}, reg_index(dst), reg_index(src), w)
}

// cmovcc_reg_mem encodes `cmovcc dst, src` from memory.
cmovcc_reg_mem :: proc(e: ^Emitter, cond: Condition, dst: Reg, src: Mem) {
	assert_gpr(dst)
	w := reg_width(dst)
	assert(w != .Byte, "cmovcc has no 8-bit form")
	emit_reg_mem(e, Insn{opcode = 0x40 + u8(cond), two_byte = true, rex_w = w == .Qword}, reg_index(dst), src, w)
}

// ----------------------------------------------------------------------------
// jmp / jcc / call / ret
// ----------------------------------------------------------------------------

// jmp_label encodes `jmp target` with a rel32 displacement, patched by
// label_resolve.
jmp_label :: proc(e: ^Emitter, target: Label) {
	emit_byte(e, 0xE9)
	label_use(e, target)
}

// jcc_label encodes a conditional `jcc target` with a rel32 displacement,
// patched by label_resolve.
jcc_label :: proc(e: ^Emitter, cond: Condition, target: Label) {
	emit_byte(e, 0x0F)
	emit_byte(e, 0x80 + u8(cond))
	label_use(e, target)
}

// call_label encodes `call target` with a rel32 displacement, patched by
// label_resolve.
call_label :: proc(e: ^Emitter, target: Label) {
	emit_byte(e, 0xE8)
	label_use(e, target)
}

// jmp_reg encodes the indirect `jmp target` through a 64-bit GPR.
jmp_reg :: proc(e: ^Emitter, target: Reg) {
	assert_gpr(target)
	assert(reg_width(target) == .Qword, "indirect jump target must be 64-bit")
	emit_reg_reg(e, Insn{opcode = 0xFF}, 4, reg_index(target), .Qword)
}

// jmp_mem encodes the indirect `jmp target` through memory.
jmp_mem :: proc(e: ^Emitter, target: Mem) {
	emit_reg_mem(e, Insn{opcode = 0xFF}, 4, target, .Qword)
}

// call_reg encodes the indirect `call target` through a 64-bit GPR.
call_reg :: proc(e: ^Emitter, target: Reg) {
	assert_gpr(target)
	assert(reg_width(target) == .Qword, "indirect call target must be 64-bit")
	emit_reg_reg(e, Insn{opcode = 0xFF}, 2, reg_index(target), .Qword)
}

// call_mem encodes the indirect `call target` through memory.
call_mem :: proc(e: ^Emitter, target: Mem) {
	emit_reg_mem(e, Insn{opcode = 0xFF}, 2, target, .Qword)
}

// ret encodes a near return.
ret :: proc(e: ^Emitter) {
	emit_byte(e, 0xC3)
}

// ret_imm encodes a near return that pops imm bytes from the stack.
ret_imm :: proc(e: ^Emitter, imm: u16) {
	emit_byte(e, 0xC2)
	emit_u16(e, imm)
}

// ----------------------------------------------------------------------------
// push / pop
// ----------------------------------------------------------------------------

// push_reg encodes `push src` for a 64-bit GPR.
push_reg :: proc(e: ^Emitter, src: Reg) {
	assert_gpr(src)
	assert(reg_width(src) == .Qword, "push operand must be 64-bit")
	emit_op_plus_reg(e, 0x50, reg_index(src), false, false)
}

// pop_reg encodes `pop dst` for a 64-bit GPR.
pop_reg :: proc(e: ^Emitter, dst: Reg) {
	assert_gpr(dst)
	assert(reg_width(dst) == .Qword, "pop operand must be 64-bit")
	emit_op_plus_reg(e, 0x58, reg_index(dst), false, false)
}

// push_imm encodes `push imm`.
push_imm :: proc(e: ^Emitter, imm: i32) {
	if imm >= -128 && imm <= 127 {
		emit_byte(e, 0x6A)
		emit_byte(e, byte(imm))
		return
	}
	emit_byte(e, 0x68)
	emit_u32(e, u32(imm))
}

// push_mem encodes `push src` from memory.
push_mem :: proc(e: ^Emitter, src: Mem) {
	emit_reg_mem(e, Insn{opcode = 0xFF}, 6, src, .Qword)
}

// pop_mem encodes `pop dst` into memory.
pop_mem :: proc(e: ^Emitter, dst: Mem) {
	emit_reg_mem(e, Insn{opcode = 0x8F}, 0, dst, .Qword)
}

// ----------------------------------------------------------------------------
// fixed instructions
// ----------------------------------------------------------------------------

// syscall encodes the SYSCALL instruction.
syscall :: proc(e: ^Emitter) {
	emit_byte(e, 0x0F)
	emit_byte(e, 0x05)
}

// ud2 encodes the UD2 instruction.
ud2 :: proc(e: ^Emitter) {
	emit_byte(e, 0x0F)
	emit_byte(e, 0x0B)
}

// int3 encodes the INT3 breakpoint instruction.
int3 :: proc(e: ^Emitter) {
	emit_byte(e, 0xCC)
}

// nop encodes the one-byte NOP.
nop :: proc(e: ^Emitter) {
	emit_byte(e, 0x90)
}

// ----------------------------------------------------------------------------
// SSE2 scalar
// ----------------------------------------------------------------------------

@(private)
sse_rr :: proc(e: ^Emitter, prefix, opcode: u8, reg_field, rm_reg: Reg, rex_w: bool) {
	emit_reg_reg(e, Insn{prefix = prefix, opcode = opcode, two_byte = true, rex_w = rex_w}, reg_index(reg_field), reg_index(rm_reg), .Dword)
}

@(private)
sse_rm :: proc(e: ^Emitter, prefix, opcode: u8, reg_field: Reg, mem: Mem, rex_w: bool) {
	emit_reg_mem(e, Insn{prefix = prefix, opcode = opcode, two_byte = true, rex_w = rex_w}, reg_index(reg_field), mem, .Dword)
}

// movss_reg_reg encodes `movss dst, src` between two XMM registers.
movss_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0xF3, 0x10, dst, src, false)
}

// movss_reg_mem encodes `movss dst, src` loading a scalar single from memory.
movss_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0xF3, 0x10, dst, src, false)
}

// movss_mem_reg encodes `movss dst, src` storing a scalar single to memory.
movss_mem_reg :: proc(e: ^Emitter, dst: Mem, src: Reg) {
	assert_xmm(src)
	sse_rm(e, 0xF3, 0x11, src, dst, false)
}

// movsd_reg_reg encodes `movsd dst, src` between two XMM registers.
movsd_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0xF2, 0x10, dst, src, false)
}

// movsd_reg_mem encodes `movsd dst, src` loading a scalar double from memory.
movsd_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0xF2, 0x10, dst, src, false)
}

// movsd_mem_reg encodes `movsd dst, src` storing a scalar double to memory.
movsd_mem_reg :: proc(e: ^Emitter, dst: Mem, src: Reg) {
	assert_xmm(src)
	sse_rm(e, 0xF2, 0x11, src, dst, false)
}

// addss_reg_reg encodes `addss dst, src`.
addss_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0xF3, 0x58, dst, src, false)
}

// addss_reg_mem encodes `addss dst, src` from memory.
addss_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0xF3, 0x58, dst, src, false)
}

// addsd_reg_reg encodes `addsd dst, src`.
addsd_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0xF2, 0x58, dst, src, false)
}

// addsd_reg_mem encodes `addsd dst, src` from memory.
addsd_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0xF2, 0x58, dst, src, false)
}

// subss_reg_reg encodes `subss dst, src`.
subss_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0xF3, 0x5C, dst, src, false)
}

// subss_reg_mem encodes `subss dst, src` from memory.
subss_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0xF3, 0x5C, dst, src, false)
}

// subsd_reg_reg encodes `subsd dst, src`.
subsd_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0xF2, 0x5C, dst, src, false)
}

// subsd_reg_mem encodes `subsd dst, src` from memory.
subsd_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0xF2, 0x5C, dst, src, false)
}

// mulss_reg_reg encodes `mulss dst, src`.
mulss_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0xF3, 0x59, dst, src, false)
}

// mulss_reg_mem encodes `mulss dst, src` from memory.
mulss_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0xF3, 0x59, dst, src, false)
}

// mulsd_reg_reg encodes `mulsd dst, src`.
mulsd_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0xF2, 0x59, dst, src, false)
}

// mulsd_reg_mem encodes `mulsd dst, src` from memory.
mulsd_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0xF2, 0x59, dst, src, false)
}

// divss_reg_reg encodes `divss dst, src`.
divss_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0xF3, 0x5E, dst, src, false)
}

// divss_reg_mem encodes `divss dst, src` from memory.
divss_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0xF3, 0x5E, dst, src, false)
}

// divsd_reg_reg encodes `divsd dst, src`.
divsd_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0xF2, 0x5E, dst, src, false)
}

// divsd_reg_mem encodes `divsd dst, src` from memory.
divsd_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0xF2, 0x5E, dst, src, false)
}

// ucomiss_reg_reg encodes `ucomiss dst, src`.
ucomiss_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0, 0x2E, dst, src, false)
}

// ucomiss_reg_mem encodes `ucomiss dst, src` from memory.
ucomiss_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0, 0x2E, dst, src, false)
}

// ucomisd_reg_reg encodes `ucomisd dst, src`.
ucomisd_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_rr(e, 0x66, 0x2E, dst, src, false)
}

// ucomisd_reg_mem encodes `ucomisd dst, src` from memory.
ucomisd_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_rm(e, 0x66, 0x2E, dst, src, false)
}

// cvtsi2ss_reg_reg encodes `cvtsi2ss dst, src` converting a 32 or 64-bit GPR.
cvtsi2ss_reg_reg :: proc(e: ^Emitter, dst: Reg, src: Reg) {
	assert_xmm(dst)
	assert_gpr(src)
	w := reg_width(src)
	assert(w == .Dword || w == .Qword, "cvtsi2ss source must be 32 or 64-bit")
	sse_rr(e, 0xF3, 0x2A, dst, src, w == .Qword)
}

// cvtsi2ss_reg_mem encodes `cvtsi2ss dst, src` from memory; src_width gives the
// integer operand size (Dword or Qword).
cvtsi2ss_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem, src_width: Reg_Width) {
	assert_xmm(dst)
	assert(src_width == .Dword || src_width == .Qword, "cvtsi2ss source must be 32 or 64-bit")
	sse_rm(e, 0xF3, 0x2A, dst, src, src_width == .Qword)
}

// cvtsi2sd_reg_reg encodes `cvtsi2sd dst, src` converting a 32 or 64-bit GPR.
cvtsi2sd_reg_reg :: proc(e: ^Emitter, dst: Reg, src: Reg) {
	assert_xmm(dst)
	assert_gpr(src)
	w := reg_width(src)
	assert(w == .Dword || w == .Qword, "cvtsi2sd source must be 32 or 64-bit")
	sse_rr(e, 0xF2, 0x2A, dst, src, w == .Qword)
}

// cvtsi2sd_reg_mem encodes `cvtsi2sd dst, src` from memory; src_width gives the
// integer operand size (Dword or Qword).
cvtsi2sd_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem, src_width: Reg_Width) {
	assert_xmm(dst)
	assert(src_width == .Dword || src_width == .Qword, "cvtsi2sd source must be 32 or 64-bit")
	sse_rm(e, 0xF2, 0x2A, dst, src, src_width == .Qword)
}

// cvttss2si_reg_reg encodes `cvttss2si dst, src` truncating to a 32 or 64-bit GPR.
cvttss2si_reg_reg :: proc(e: ^Emitter, dst: Reg, src: Reg) {
	assert_gpr(dst)
	assert_xmm(src)
	w := reg_width(dst)
	assert(w == .Dword || w == .Qword, "cvttss2si destination must be 32 or 64-bit")
	sse_rr(e, 0xF3, 0x2C, dst, src, w == .Qword)
}

// cvttss2si_reg_mem encodes `cvttss2si dst, src` from memory.
cvttss2si_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	w := reg_width(dst)
	assert(w == .Dword || w == .Qword, "cvttss2si destination must be 32 or 64-bit")
	sse_rm(e, 0xF3, 0x2C, dst, src, w == .Qword)
}

// cvttsd2si_reg_reg encodes `cvttsd2si dst, src` truncating to a 32 or 64-bit GPR.
cvttsd2si_reg_reg :: proc(e: ^Emitter, dst: Reg, src: Reg) {
	assert_gpr(dst)
	assert_xmm(src)
	w := reg_width(dst)
	assert(w == .Dword || w == .Qword, "cvttsd2si destination must be 32 or 64-bit")
	sse_rr(e, 0xF2, 0x2C, dst, src, w == .Qword)
}

// cvttsd2si_reg_mem encodes `cvttsd2si dst, src` from memory.
cvttsd2si_reg_mem :: proc(e: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	w := reg_width(dst)
	assert(w == .Dword || w == .Qword, "cvttsd2si destination must be 32 or 64-bit")
	sse_rm(e, 0xF2, 0x2C, dst, src, w == .Qword)
}

// movq_reg_reg encodes `movq` between an XMM register and a 64-bit GPR; the
// direction follows the operand classes.
movq_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	if reg_class(dst) == .Vector {
		assert_xmm(dst)
		assert_gpr(src)
		assert(reg_width(src) == .Qword, "movq GPR operand must be 64-bit")
		sse_rr(e, 0x66, 0x6E, dst, src, true)
		return
	}
	assert_gpr(dst)
	assert_xmm(src)
	assert(reg_width(dst) == .Qword, "movq GPR operand must be 64-bit")
	sse_rr(e, 0x66, 0x7E, src, dst, true)
}

// movd_reg_reg encodes `movd` between an XMM register and a 32-bit GPR; the
// direction follows the operand classes.
movd_reg_reg :: proc(e: ^Emitter, dst, src: Reg) {
	if reg_class(dst) == .Vector {
		assert_xmm(dst)
		assert_gpr(src)
		assert(reg_width(src) == .Dword, "movd GPR operand must be 32-bit")
		sse_rr(e, 0x66, 0x6E, dst, src, false)
		return
	}
	assert_gpr(dst)
	assert_xmm(src)
	assert(reg_width(dst) == .Dword, "movd GPR operand must be 32-bit")
	sse_rr(e, 0x66, 0x7E, src, dst, false)
}

package x64

import "core:mem"

// Ill-formed operands are a programming error: instruction selection above this
// package is expected to supply well-formed operands, so they trip an assert.

// Condition is an x86 condition code, shared by setcc, cmovcc and jcc.
Condition :: enum u8 {
	Overflow         = 0,
	Not_Overflow     = 1,
	Below            = 2,
	Above_Or_Equal   = 3,
	Equal            = 4,
	Not_Equal        = 5,
	Below_Or_Equal   = 6,
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

Label :: distinct u32

LABEL_NONE :: Label(0)

Emitter :: struct {
	code:   [dynamic]byte,
	labels: [dynamic]Label_State,
	fixups: [dynamic]Fixup,
}

@(private)
Label_State :: struct {
	bound:  bool,
	offset: int,
}

@(private)
Fixup :: struct {
	offset: int,
	label:  Label,
}

emitter_init :: proc(emitter: ^Emitter, allocator := context.allocator) -> (result: ^Emitter, err: mem.Allocator_Error) #optional_allocator_error {
	assert(emitter.code == nil, "Emitter is already initialised")
	emitter.code   = make([dynamic]byte, allocator) or_return
	emitter.labels = make([dynamic]Label_State, allocator) or_return
	emitter.fixups = make([dynamic]Fixup, allocator) or_return
	return emitter, .None
}

emitter_destroy :: proc(emitter: ^Emitter) {
	delete(emitter.code)
	delete(emitter.labels)
	delete(emitter.fixups)
	emitter^ = {}
}

// Labels created before the call become invalid.
emitter_reset :: proc(emitter: ^Emitter) {
	clear(&emitter.code)
	clear(&emitter.labels)
	clear(&emitter.fixups)
}

// The returned slice is invalidated by the next append.
emitter_bytes :: proc(emitter: ^Emitter) -> []byte {
	return emitter.code[:]
}

label_new :: proc(emitter: ^Emitter) -> Label {
	append(&emitter.labels, Label_State{})
	return Label(len(emitter.labels))
}

label_bind :: proc(emitter: ^Emitter, label: Label) {
	assert(label != LABEL_NONE, "cannot bind LABEL_NONE")
	index := int(label) - 1
	assert(index >= 0 && index < len(emitter.labels), "unknown label")
	assert(!emitter.labels[index].bound, "label bound more than once")
	emitter.labels[index].bound = true
	emitter.labels[index].offset = len(emitter.code)
}

label_offset :: proc(emitter: ^Emitter, label: Label) -> (offset: int, ok: bool) {
	if label == LABEL_NONE {
		return 0, false
	}
	index := int(label) - 1
	if index < 0 || index >= len(emitter.labels) {
		return 0, false
	}
	state := emitter.labels[index]
	if !state.bound {
		return 0, false
	}
	return state.offset, true
}

// label_use reserves a rel32 field at the current position; emit the opcode
// before calling it.
label_use :: proc(emitter: ^Emitter, label: Label) {
	assert(label != LABEL_NONE, "cannot reference LABEL_NONE")
	append(&emitter.fixups, Fixup{offset = len(emitter.code), label = label})
	emit_u32(emitter, 0)
}

// label_resolve back-patches every recorded rel32 field; each referenced label
// must be bound.
label_resolve :: proc(emitter: ^Emitter) {
	for fixup in emitter.fixups {
		state := emitter.labels[int(fixup.label) - 1]
		assert(state.bound, "unbound label referenced by a fixup")
		relative := i64(state.offset) - i64(fixup.offset + 4)
		assert(relative >= -2147483648 && relative <= 2147483647, "rel32 displacement out of range")
		value := u32(i32(relative))
		emitter.code[fixup.offset + 0] = byte(value)
		emitter.code[fixup.offset + 1] = byte(value >> 8)
		emitter.code[fixup.offset + 2] = byte(value >> 16)
		emitter.code[fixup.offset + 3] = byte(value >> 24)
	}
}

@(private)
emit_byte :: proc(emitter: ^Emitter, value: byte) {
	append(&emitter.code, value)
}

@(private)
emit_u16 :: proc(emitter: ^Emitter, value: u16) {
	append(&emitter.code, byte(value), byte(value >> 8))
}

@(private)
emit_u32 :: proc(emitter: ^Emitter, value: u32) {
	append(&emitter.code, byte(value), byte(value >> 8), byte(value >> 16), byte(value >> 24))
}

@(private)
emit_u64 :: proc(emitter: ^Emitter, value: u64) {
	append(
		&emitter.code,
		byte(value),
		byte(value >> 8),
		byte(value >> 16),
		byte(value >> 24),
		byte(value >> 32),
		byte(value >> 40),
		byte(value >> 48),
		byte(value >> 56),
	)
}

@(private)
assert_gpr :: proc(reg: Reg) {
	assert(reg_valid(reg) && reg_class(reg) == .General, "expected a general-purpose register")
}

@(private)
assert_xmm :: proc(reg: Reg) {
	assert(reg_valid(reg) && reg_class(reg) == .Vector, "expected an XMM register")
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
emit_rex :: proc(emitter: ^Emitter, rex: Rex, force: bool) {
	if !force && .W not_in rex && .R not_in rex && .X not_in rex && .B not_in rex {
		return
	}
	rex_byte: u8 = 0x40
	if .W in rex {
		rex_byte |= 0x08
	}
	if .R in rex {
		rex_byte |= 0x04
	}
	if .X in rex {
		rex_byte |= 0x02
	}
	if .B in rex {
		rex_byte |= 0x01
	}
	emit_byte(emitter, rex_byte)
}

// Opcode_Form is the REX-independent part of a ModRM instruction.
@(private)
Opcode_Form :: struct {
	mandatory_prefix: byte,
	opcode:           u8,
	two_byte:         bool,
	rex_w:            bool,
	force_rex:        bool, // SPL/BPL/SIL/DIL need a REX prefix even with no REX bit set
}

// Encoded_Mem is the ModRM/SIB/displacement tail of a memory operand.
@(private)
Encoded_Mem :: struct {
	bytes:  [6]byte,
	length: int,
	rex_x:  bool,
	rex_b:  bool,
}

@(private)
append_disp :: proc(out: ^Encoded_Mem, disp: i32, size_bytes: int) {
	switch size_bytes {
	case 1:
		out.bytes[out.length] = byte(disp)
		out.length += 1
	case 4:
		value := u32(disp)
		out.bytes[out.length + 0] = byte(value)
		out.bytes[out.length + 1] = byte(value >> 8)
		out.bytes[out.length + 2] = byte(value >> 16)
		out.bytes[out.length + 3] = byte(value >> 24)
		out.length += 4
	case:
		panic("invalid displacement size")
	}
}

// encode_mem builds the ModRM/SIB/displacement bytes for a memory operand and
// reports the index (X) and base (B) REX bits it needs.
@(private)
encode_mem :: proc(reg_field: u8, mem: Mem) -> Encoded_Mem {
	out: Encoded_Mem
	reg_bits := reg_field & 0x7
	has_base := mem.base != REG_NONE
	has_index := mem.index != REG_NONE

	if .Rip_Relative in mem.flags {
		assert(!has_base && !has_index, "RIP-relative operand must not have a base or index")
		out.bytes[0] = (0 << 6) | (reg_bits << 3) | 0x5
		out.length = 1
		append_disp(&out, mem.disp, 4)
		return out
	}

	if !has_base && !has_index {
		// Absolute [disp32]: ModRM.rm = 100 (SIB), SIB.base = 101 (no base).
		out.bytes[0] = (0 << 6) | (reg_bits << 3) | 0x4
		out.bytes[1] = (0 << 6) | (0x4 << 3) | 0x5
		out.length = 2
		append_disp(&out, mem.disp, 4)
		return out
	}

	if has_index {
		assert(mem.scale == 1 || mem.scale == 2 || mem.scale == 4 || mem.scale == 8, "invalid SIB scale")
		assert(reg_index(mem.index) != 0x4, "RSP cannot be an index register")
	}

	base_bits: u8
	use_sib := has_index
	if has_base {
		base_bits = reg_index(mem.base) & 0x7
		if base_bits == 0x4 { // an RSP/R12 base always needs a SIB byte
			use_sib = true
		}
	}

	if use_sib {
		base_absent := !has_base
		mod: u8
		switch {
		case base_absent:
			mod = 0
		case mem.disp == 0 && base_bits != 0x5:
			mod = 0
		case mem.disp >= -128 && mem.disp <= 127:
			mod = 1
		case:
			mod = 2
		}
		out.bytes[0] = (mod << 6) | (reg_bits << 3) | 0x4

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
		out.bytes[1] = (scale_bits << 6) | (index_bits << 3) | (base_absent ? 0x5 : base_bits)
		out.length = 2
		if mod == 1 {
			append_disp(&out, mem.disp, 1)
		} else if mod == 2 || base_absent {
			append_disp(&out, mem.disp, 4)
		}
		out.rex_x = has_index && reg_index(mem.index) >= 8
		out.rex_b = has_base && reg_index(mem.base) >= 8
	} else {
		mod: u8
		switch {
		case mem.disp == 0 && base_bits != 0x5: // an RBP/R13 base needs a displacement
			mod = 0
		case mem.disp >= -128 && mem.disp <= 127:
			mod = 1
		case:
			mod = 2
		}
		out.bytes[0] = (mod << 6) | (reg_bits << 3) | base_bits
		out.length = 1
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
emit_operand_size :: proc(emitter: ^Emitter, width: Reg_Width) {
	if width == .Word {
		emit_byte(emitter, 0x66)
	}
}

@(private)
emit_reg_reg :: proc(emitter: ^Emitter, form: Opcode_Form, reg_field, rm_reg: u8, width: Reg_Width) {
	emit_operand_size(emitter, width)
	if form.mandatory_prefix != 0 {
		emit_byte(emitter, form.mandatory_prefix)
	}
	rex: Rex
	if form.rex_w {
		rex |= {.W}
	}
	if reg_field >= 8 {
		rex |= {.R}
	}
	if rm_reg >= 8 {
		rex |= {.B}
	}
	emit_rex(emitter, rex, form.force_rex)
	if form.two_byte {
		emit_byte(emitter, 0x0F)
	}
	emit_byte(emitter, form.opcode)
	emit_byte(emitter, 0xC0 | ((reg_field & 0x7) << 3) | (rm_reg & 0x7))
}

@(private)
emit_reg_mem :: proc(emitter: ^Emitter, form: Opcode_Form, reg_field: u8, mem: Mem, width: Reg_Width) {
	emit_operand_size(emitter, width)
	if form.mandatory_prefix != 0 {
		emit_byte(emitter, form.mandatory_prefix)
	}
	encoded := encode_mem(reg_field, mem)
	rex: Rex
	if form.rex_w {
		rex |= {.W}
	}
	if reg_field >= 8 {
		rex |= {.R}
	}
	if encoded.rex_x {
		rex |= {.X}
	}
	if encoded.rex_b {
		rex |= {.B}
	}
	emit_rex(emitter, rex, form.force_rex)
	if form.two_byte {
		emit_byte(emitter, 0x0F)
	}
	emit_byte(emitter, form.opcode)
	for i in 0 ..< encoded.length {
		emit_byte(emitter, encoded.bytes[i])
	}
}

// The opcode's low three bits carry the register number (B0+rb, B8+rd, 50+rd,
// 58+rd).
@(private)
emit_op_plus_reg :: proc(emitter: ^Emitter, opcode_base: u8, register_number: u8, rex_w, force_rex: bool) {
	rex: Rex
	if rex_w {
		rex |= {.W}
	}
	if register_number >= 8 {
		rex |= {.B}
	}
	emit_rex(emitter, rex, force_rex)
	emit_byte(emitter, opcode_base + (register_number & 0x7))
}

mov_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	width := reg_width(dst)
	assert(reg_width(src) == width, "operand width mismatch")
	byte_form := width == .Byte
	force_rex := byte_form && (reg_index(src) >= 4 || reg_index(dst) >= 4)
	emit_reg_reg(emitter, Opcode_Form{opcode = byte_form ? 0x88 : 0x89, rex_w = width == .Qword, force_rex = force_rex}, reg_index(src), reg_index(dst), width)
}

mov_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	width := reg_width(dst)
	byte_form := width == .Byte
	force_rex := byte_form && reg_index(dst) >= 4
	emit_reg_mem(emitter, Opcode_Form{opcode = byte_form ? 0x8A : 0x8B, rex_w = width == .Qword, force_rex = force_rex}, reg_index(dst), src, width)
}

mov_mem_reg :: proc(emitter: ^Emitter, dst: Mem, src: Reg) {
	assert_gpr(src)
	width := reg_width(src)
	byte_form := width == .Byte
	force_rex := byte_form && reg_index(src) >= 4
	emit_reg_mem(emitter, Opcode_Form{opcode = byte_form ? 0x88 : 0x89, rex_w = width == .Qword, force_rex = force_rex}, reg_index(src), dst, width)
}

// For a 64-bit destination, mov_reg_imm uses the sign-extended 32-bit form when
// imm fits and the full 64-bit movabs form otherwise.
mov_reg_imm :: proc(emitter: ^Emitter, dst: Reg, imm: i64) {
	assert_gpr(dst)
	width := reg_width(dst)
	switch width {
	case .Byte:
		assert(imm_fits(imm, .Byte), "immediate out of range")
		emit_op_plus_reg(emitter, 0xB0, reg_index(dst), false, reg_index(dst) >= 4)
		emit_byte(emitter, byte(imm))
	case .Word:
		assert(imm_fits(imm, .Word), "immediate out of range")
		emit_byte(emitter, 0x66)
		emit_op_plus_reg(emitter, 0xB8, reg_index(dst), false, false)
		emit_u16(emitter, u16(imm))
	case .Dword:
		assert(imm_fits(imm, .Dword), "immediate out of range")
		emit_op_plus_reg(emitter, 0xB8, reg_index(dst), false, false)
		emit_u32(emitter, u32(imm))
	case .Qword:
		if imm >= -2147483648 && imm <= 2147483647 {
			emit_reg_reg(emitter, Opcode_Form{opcode = 0xC7, rex_w = true}, 0, reg_index(dst), .Qword)
			emit_u32(emitter, u32(i32(imm)))
		} else {
			movabs_reg_imm64(emitter, dst, imm)
		}
	}
}

movabs_reg_imm64 :: proc(emitter: ^Emitter, dst: Reg, imm: i64) {
	assert_gpr(dst)
	assert(reg_width(dst) == .Qword, "movabs destination must be 64-bit")
	emit_op_plus_reg(emitter, 0xB8, reg_index(dst), true, false)
	emit_u64(emitter, u64(imm))
}

movzx_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	dst_width := reg_width(dst)
	src_width := reg_width(src)
	assert(dst_width == .Word || dst_width == .Dword || dst_width == .Qword, "movzx destination must be 16, 32 or 64-bit")
	assert(src_width == .Byte || src_width == .Word, "movzx source must be 8 or 16-bit")
	opcode: u8 = src_width == .Byte ? 0xB6 : 0xB7
	emit_reg_reg(emitter, Opcode_Form{opcode = opcode, two_byte = true, rex_w = dst_width == .Qword}, reg_index(dst), reg_index(src), dst_width)
}

movzx_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem, src_width: Reg_Width) {
	assert_gpr(dst)
	dst_width := reg_width(dst)
	assert(dst_width == .Word || dst_width == .Dword || dst_width == .Qword, "movzx destination must be 16, 32 or 64-bit")
	assert(src_width == .Byte || src_width == .Word, "movzx source must be 8 or 16-bit")
	opcode: u8 = src_width == .Byte ? 0xB6 : 0xB7
	emit_reg_mem(emitter, Opcode_Form{opcode = opcode, two_byte = true, rex_w = dst_width == .Qword}, reg_index(dst), src, dst_width)
}

movsx_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	dst_width := reg_width(dst)
	src_width := reg_width(src)
	assert(dst_width == .Word || dst_width == .Dword || dst_width == .Qword, "movsx destination must be 16, 32 or 64-bit")
	assert(src_width == .Byte || src_width == .Word, "movsx source must be 8 or 16-bit")
	opcode: u8 = src_width == .Byte ? 0xBE : 0xBF
	emit_reg_reg(emitter, Opcode_Form{opcode = opcode, two_byte = true, rex_w = dst_width == .Qword}, reg_index(dst), reg_index(src), dst_width)
}

movsx_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem, src_width: Reg_Width) {
	assert_gpr(dst)
	dst_width := reg_width(dst)
	assert(dst_width == .Word || dst_width == .Dword || dst_width == .Qword, "movsx destination must be 16, 32 or 64-bit")
	assert(src_width == .Byte || src_width == .Word, "movsx source must be 8 or 16-bit")
	opcode: u8 = src_width == .Byte ? 0xBE : 0xBF
	emit_reg_mem(emitter, Opcode_Form{opcode = opcode, two_byte = true, rex_w = dst_width == .Qword}, reg_index(dst), src, dst_width)
}

movsxd_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	assert(reg_width(dst) == .Qword, "movsxd destination must be 64-bit")
	assert(reg_width(src) == .Dword, "movsxd source must be 32-bit")
	emit_reg_reg(emitter, Opcode_Form{opcode = 0x63, rex_w = true}, reg_index(dst), reg_index(src), .Dword)
}

movsxd_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	assert(reg_width(dst) == .Qword, "movsxd destination must be 64-bit")
	emit_reg_mem(emitter, Opcode_Form{opcode = 0x63, rex_w = true}, reg_index(dst), src, .Dword)
}

lea_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	width := reg_width(dst)
	assert(width != .Byte, "lea has no 8-bit form")
	emit_reg_mem(emitter, Opcode_Form{opcode = 0x8D, rex_w = width == .Qword}, reg_index(dst), src, width)
}

@(private)
Alu_Operation :: enum u8 {
	Add = 0,
	Or  = 1,
	And = 4,
	Sub = 5,
	Xor = 6,
	Cmp = 7,
}

@(private)
alu_reg_reg :: proc(emitter: ^Emitter, operation: Alu_Operation, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	width := reg_width(dst)
	assert(reg_width(src) == width, "operand width mismatch")
	byte_form := width == .Byte
	opcode := u8(operation) * 8
	if !byte_form {
		opcode += 1
	}
	force_rex := byte_form && (reg_index(src) >= 4 || reg_index(dst) >= 4)
	emit_reg_reg(emitter, Opcode_Form{opcode = opcode, rex_w = width == .Qword, force_rex = force_rex}, reg_index(src), reg_index(dst), width)
}

@(private)
alu_reg_mem :: proc(emitter: ^Emitter, operation: Alu_Operation, dst: Reg, src: Mem) {
	assert_gpr(dst)
	width := reg_width(dst)
	byte_form := width == .Byte
	opcode := u8(operation) * 8 + 2
	if !byte_form {
		opcode += 1
	}
	force_rex := byte_form && reg_index(dst) >= 4
	emit_reg_mem(emitter, Opcode_Form{opcode = opcode, rex_w = width == .Qword, force_rex = force_rex}, reg_index(dst), src, width)
}

@(private)
alu_mem_reg :: proc(emitter: ^Emitter, operation: Alu_Operation, dst: Mem, src: Reg) {
	assert_gpr(src)
	width := reg_width(src)
	byte_form := width == .Byte
	opcode := u8(operation) * 8
	if !byte_form {
		opcode += 1
	}
	force_rex := byte_form && reg_index(src) >= 4
	emit_reg_mem(emitter, Opcode_Form{opcode = opcode, rex_w = width == .Qword, force_rex = force_rex}, reg_index(src), dst, width)
}

@(private)
alu_reg_imm :: proc(emitter: ^Emitter, operation: Alu_Operation, dst: Reg, imm: i64) {
	assert_gpr(dst)
	width := reg_width(dst)
	if width == .Byte {
		assert(imm_fits(imm, .Byte), "immediate out of range")
		force_rex := reg_index(dst) >= 4
		emit_reg_reg(emitter, Opcode_Form{opcode = 0x80, rex_w = width == .Qword, force_rex = force_rex}, u8(operation), reg_index(dst), .Byte)
		emit_byte(emitter, byte(imm))
		return
	}
	if imm >= -128 && imm <= 127 {
		emit_reg_reg(emitter, Opcode_Form{opcode = 0x83, rex_w = width == .Qword}, u8(operation), reg_index(dst), width)
		emit_byte(emitter, byte(imm))
		return
	}
	switch width {
	case .Word:
		assert(imm >= -32768 && imm <= 65535, "immediate out of range")
		emit_reg_reg(emitter, Opcode_Form{opcode = 0x81, rex_w = width == .Qword}, u8(operation), reg_index(dst), width)
		emit_u16(emitter, u16(imm))
	case .Dword:
		assert(imm >= -2147483648 && imm <= 4294967295, "immediate out of range")
		emit_reg_reg(emitter, Opcode_Form{opcode = 0x81, rex_w = width == .Qword}, u8(operation), reg_index(dst), width)
		emit_u32(emitter, u32(imm))
	case .Qword:
		assert(imm >= -2147483648 && imm <= 2147483647, "immediate does not fit the sign-extended 32-bit form")
		emit_reg_reg(emitter, Opcode_Form{opcode = 0x81, rex_w = width == .Qword}, u8(operation), reg_index(dst), width)
		emit_u32(emitter, u32(i32(imm)))
	case .Byte:
		return
	}
}

add_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {alu_reg_reg(emitter, .Add, dst, src)}
add_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(emitter, .Add, dst, src)}
add_mem_reg :: proc(emitter: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(emitter, .Add, dst, src)}
add_reg_imm :: proc(emitter: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(emitter, .Add, dst, imm)}

sub_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {alu_reg_reg(emitter, .Sub, dst, src)}
sub_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(emitter, .Sub, dst, src)}
sub_mem_reg :: proc(emitter: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(emitter, .Sub, dst, src)}
sub_reg_imm :: proc(emitter: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(emitter, .Sub, dst, imm)}

and_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {alu_reg_reg(emitter, .And, dst, src)}
and_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(emitter, .And, dst, src)}
and_mem_reg :: proc(emitter: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(emitter, .And, dst, src)}
and_reg_imm :: proc(emitter: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(emitter, .And, dst, imm)}

or_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {alu_reg_reg(emitter, .Or, dst, src)}
or_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(emitter, .Or, dst, src)}
or_mem_reg :: proc(emitter: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(emitter, .Or, dst, src)}
or_reg_imm :: proc(emitter: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(emitter, .Or, dst, imm)}

xor_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {alu_reg_reg(emitter, .Xor, dst, src)}
xor_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(emitter, .Xor, dst, src)}
xor_mem_reg :: proc(emitter: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(emitter, .Xor, dst, src)}
xor_reg_imm :: proc(emitter: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(emitter, .Xor, dst, imm)}

cmp_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {alu_reg_reg(emitter, .Cmp, dst, src)}
cmp_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {alu_reg_mem(emitter, .Cmp, dst, src)}
cmp_mem_reg :: proc(emitter: ^Emitter, dst: Mem, src: Reg) {alu_mem_reg(emitter, .Cmp, dst, src)}
cmp_reg_imm :: proc(emitter: ^Emitter, dst: Reg, imm: i64) {alu_reg_imm(emitter, .Cmp, dst, imm)}

test_reg_reg :: proc(emitter: ^Emitter, left, right: Reg) {
	assert_gpr(left)
	assert_gpr(right)
	width := reg_width(left)
	assert(reg_width(right) == width, "operand width mismatch")
	byte_form := width == .Byte
	force_rex := byte_form && (reg_index(left) >= 4 || reg_index(right) >= 4)
	emit_reg_reg(emitter, Opcode_Form{opcode = byte_form ? 0x84 : 0x85, rex_w = width == .Qword, force_rex = force_rex}, reg_index(right), reg_index(left), width)
}

test_reg_mem :: proc(emitter: ^Emitter, reg: Reg, mem: Mem) {
	assert_gpr(reg)
	width := reg_width(reg)
	byte_form := width == .Byte
	force_rex := byte_form && reg_index(reg) >= 4
	emit_reg_mem(emitter, Opcode_Form{opcode = byte_form ? 0x84 : 0x85, rex_w = width == .Qword, force_rex = force_rex}, reg_index(reg), mem, width)
}

// test is symmetric, so test_mem_reg encodes the same bytes as test_reg_mem.
test_mem_reg :: proc(emitter: ^Emitter, mem: Mem, reg: Reg) {
	test_reg_mem(emitter, reg, mem)
}

test_reg_imm :: proc(emitter: ^Emitter, reg: Reg, imm: i64) {
	assert_gpr(reg)
	width := reg_width(reg)
	if width == .Byte {
		assert(imm_fits(imm, .Byte), "immediate out of range")
		force_rex := reg_index(reg) >= 4
		emit_reg_reg(emitter, Opcode_Form{opcode = 0xF6, rex_w = width == .Qword, force_rex = force_rex}, 0, reg_index(reg), .Byte)
		emit_byte(emitter, byte(imm))
		return
	}
	emit_reg_reg(emitter, Opcode_Form{opcode = 0xF7, rex_w = width == .Qword}, 0, reg_index(reg), width)
	switch width {
	case .Word:
		assert(imm >= -32768 && imm <= 65535, "immediate out of range")
		emit_u16(emitter, u16(imm))
	case .Dword:
		assert(imm >= -2147483648 && imm <= 4294967295, "immediate out of range")
		emit_u32(emitter, u32(imm))
	case .Qword:
		assert(imm >= -2147483648 && imm <= 2147483647, "immediate does not fit the sign-extended 32-bit form")
		emit_u32(emitter, u32(i32(imm)))
	case .Byte:
		return
	}
}

imul_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	width := reg_width(dst)
	assert(width != .Byte, "imul has no 8-bit two-operand form")
	assert(reg_width(src) == width, "operand width mismatch")
	emit_reg_reg(emitter, Opcode_Form{opcode = 0xAF, two_byte = true, rex_w = width == .Qword}, reg_index(dst), reg_index(src), width)
}

imul_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	width := reg_width(dst)
	assert(width != .Byte, "imul has no 8-bit two-operand form")
	emit_reg_mem(emitter, Opcode_Form{opcode = 0xAF, two_byte = true, rex_w = width == .Qword}, reg_index(dst), src, width)
}

imul_reg_reg_imm :: proc(emitter: ^Emitter, dst, src: Reg, imm: i32) {
	assert_gpr(dst)
	assert_gpr(src)
	width := reg_width(dst)
	assert(width != .Byte, "imul has no 8-bit three-operand form")
	assert(reg_width(src) == width, "operand width mismatch")
	if imm >= -128 && imm <= 127 {
		emit_reg_reg(emitter, Opcode_Form{opcode = 0x6B, rex_w = width == .Qword}, reg_index(dst), reg_index(src), width)
		emit_byte(emitter, byte(imm))
		return
	}
	emit_reg_reg(emitter, Opcode_Form{opcode = 0x69, rex_w = width == .Qword}, reg_index(dst), reg_index(src), width)
	switch width {
	case .Word:
		emit_u16(emitter, u16(imm))
	case .Dword:
		emit_u32(emitter, u32(imm))
	case .Qword:
		emit_u32(emitter, u32(imm))
	case .Byte:
		return
	}
}

// digit is the ModRM.reg field selecting the operation within opcode group 3.
@(private)
unary_reg :: proc(emitter: ^Emitter, digit: u8, reg: Reg) {
	assert_gpr(reg)
	width := reg_width(reg)
	byte_form := width == .Byte
	force_rex := byte_form && reg_index(reg) >= 4
	emit_reg_reg(emitter, Opcode_Form{opcode = byte_form ? 0xF6 : 0xF7, rex_w = width == .Qword, force_rex = force_rex}, digit, reg_index(reg), width)
}

@(private)
unary_mem :: proc(emitter: ^Emitter, digit: u8, mem: Mem, width: Reg_Width) {
	emit_reg_mem(emitter, Opcode_Form{opcode = width == .Byte ? 0xF6 : 0xF7, rex_w = width == .Qword}, digit, mem, width)
}

div_reg :: proc(emitter: ^Emitter, src: Reg) {unary_reg(emitter, 6, src)}
div_mem :: proc(emitter: ^Emitter, src: Mem, width: Reg_Width) {unary_mem(emitter, 6, src, width)}
idiv_reg :: proc(emitter: ^Emitter, src: Reg) {unary_reg(emitter, 7, src)}
idiv_mem :: proc(emitter: ^Emitter, src: Mem, width: Reg_Width) {unary_mem(emitter, 7, src, width)}
neg_reg :: proc(emitter: ^Emitter, dst: Reg) {unary_reg(emitter, 3, dst)}
neg_mem :: proc(emitter: ^Emitter, dst: Mem, width: Reg_Width) {unary_mem(emitter, 3, dst, width)}
not_reg :: proc(emitter: ^Emitter, dst: Reg) {unary_reg(emitter, 2, dst)}
not_mem :: proc(emitter: ^Emitter, dst: Mem, width: Reg_Width) {unary_mem(emitter, 2, dst, width)}

cqo :: proc(emitter: ^Emitter) {
	emit_byte(emitter, 0x48)
	emit_byte(emitter, 0x99)
}

cdq :: proc(emitter: ^Emitter) {
	emit_byte(emitter, 0x99)
}

@(private)
shift_imm :: proc(emitter: ^Emitter, digit: u8, dst: Reg, imm: u8) {
	assert_gpr(dst)
	width := reg_width(dst)
	byte_form := width == .Byte
	force_rex := byte_form && reg_index(dst) >= 4
	emit_reg_reg(emitter, Opcode_Form{opcode = byte_form ? 0xC0 : 0xC1, rex_w = width == .Qword, force_rex = force_rex}, digit, reg_index(dst), width)
	emit_byte(emitter, imm)
}

@(private)
shift_cl :: proc(emitter: ^Emitter, digit: u8, dst: Reg) {
	assert_gpr(dst)
	width := reg_width(dst)
	byte_form := width == .Byte
	force_rex := byte_form && reg_index(dst) >= 4
	emit_reg_reg(emitter, Opcode_Form{opcode = byte_form ? 0xD2 : 0xD3, rex_w = width == .Qword, force_rex = force_rex}, digit, reg_index(dst), width)
}

@(private)
shift_imm_mem :: proc(emitter: ^Emitter, digit: u8, dst: Mem, imm: u8, width: Reg_Width) {
	emit_reg_mem(emitter, Opcode_Form{opcode = width == .Byte ? 0xC0 : 0xC1, rex_w = width == .Qword}, digit, dst, width)
	emit_byte(emitter, imm)
}

@(private)
shift_cl_mem :: proc(emitter: ^Emitter, digit: u8, dst: Mem, width: Reg_Width) {
	emit_reg_mem(emitter, Opcode_Form{opcode = width == .Byte ? 0xD2 : 0xD3, rex_w = width == .Qword}, digit, dst, width)
}

shl_reg_imm :: proc(emitter: ^Emitter, dst: Reg, imm: u8) {shift_imm(emitter, 4, dst, imm)}
shr_reg_imm :: proc(emitter: ^Emitter, dst: Reg, imm: u8) {shift_imm(emitter, 5, dst, imm)}
sar_reg_imm :: proc(emitter: ^Emitter, dst: Reg, imm: u8) {shift_imm(emitter, 7, dst, imm)}
shl_reg_cl :: proc(emitter: ^Emitter, dst: Reg) {shift_cl(emitter, 4, dst)}
shr_reg_cl :: proc(emitter: ^Emitter, dst: Reg) {shift_cl(emitter, 5, dst)}
sar_reg_cl :: proc(emitter: ^Emitter, dst: Reg) {shift_cl(emitter, 7, dst)}
shl_mem_imm :: proc(emitter: ^Emitter, dst: Mem, imm: u8, width: Reg_Width) {shift_imm_mem(emitter, 4, dst, imm, width)}
shr_mem_imm :: proc(emitter: ^Emitter, dst: Mem, imm: u8, width: Reg_Width) {shift_imm_mem(emitter, 5, dst, imm, width)}
sar_mem_imm :: proc(emitter: ^Emitter, dst: Mem, imm: u8, width: Reg_Width) {shift_imm_mem(emitter, 7, dst, imm, width)}
shl_mem_cl :: proc(emitter: ^Emitter, dst: Mem, width: Reg_Width) {shift_cl_mem(emitter, 4, dst, width)}
shr_mem_cl :: proc(emitter: ^Emitter, dst: Mem, width: Reg_Width) {shift_cl_mem(emitter, 5, dst, width)}
sar_mem_cl :: proc(emitter: ^Emitter, dst: Mem, width: Reg_Width) {shift_cl_mem(emitter, 7, dst, width)}

setcc_reg :: proc(emitter: ^Emitter, condition: Condition, dst: Reg) {
	assert_gpr(dst)
	assert(reg_width(dst) == .Byte, "setcc destination must be 8-bit")
	force_rex := reg_index(dst) >= 4
	emit_reg_reg(emitter, Opcode_Form{opcode = 0x90 + u8(condition), two_byte = true, force_rex = force_rex}, 0, reg_index(dst), .Byte)
}

setcc_mem :: proc(emitter: ^Emitter, condition: Condition, dst: Mem) {
	emit_reg_mem(emitter, Opcode_Form{opcode = 0x90 + u8(condition), two_byte = true}, 0, dst, .Byte)
}

cmovcc_reg_reg :: proc(emitter: ^Emitter, condition: Condition, dst, src: Reg) {
	assert_gpr(dst)
	assert_gpr(src)
	width := reg_width(dst)
	assert(width != .Byte, "cmovcc has no 8-bit form")
	assert(reg_width(src) == width, "operand width mismatch")
	emit_reg_reg(emitter, Opcode_Form{opcode = 0x40 + u8(condition), two_byte = true, rex_w = width == .Qword}, reg_index(dst), reg_index(src), width)
}

cmovcc_reg_mem :: proc(emitter: ^Emitter, condition: Condition, dst: Reg, src: Mem) {
	assert_gpr(dst)
	width := reg_width(dst)
	assert(width != .Byte, "cmovcc has no 8-bit form")
	emit_reg_mem(emitter, Opcode_Form{opcode = 0x40 + u8(condition), two_byte = true, rex_w = width == .Qword}, reg_index(dst), src, width)
}

jmp_label :: proc(emitter: ^Emitter, target: Label) {
	emit_byte(emitter, 0xE9)
	label_use(emitter, target)
}

jcc_label :: proc(emitter: ^Emitter, condition: Condition, target: Label) {
	emit_byte(emitter, 0x0F)
	emit_byte(emitter, 0x80 + u8(condition))
	label_use(emitter, target)
}

call_label :: proc(emitter: ^Emitter, target: Label) {
	emit_byte(emitter, 0xE8)
	label_use(emitter, target)
}

jmp_reg :: proc(emitter: ^Emitter, target: Reg) {
	assert_gpr(target)
	assert(reg_width(target) == .Qword, "indirect jump target must be 64-bit")
	emit_reg_reg(emitter, Opcode_Form{opcode = 0xFF}, 4, reg_index(target), .Qword)
}

jmp_mem :: proc(emitter: ^Emitter, target: Mem) {
	emit_reg_mem(emitter, Opcode_Form{opcode = 0xFF}, 4, target, .Qword)
}

call_reg :: proc(emitter: ^Emitter, target: Reg) {
	assert_gpr(target)
	assert(reg_width(target) == .Qword, "indirect call target must be 64-bit")
	emit_reg_reg(emitter, Opcode_Form{opcode = 0xFF}, 2, reg_index(target), .Qword)
}

call_mem :: proc(emitter: ^Emitter, target: Mem) {
	emit_reg_mem(emitter, Opcode_Form{opcode = 0xFF}, 2, target, .Qword)
}

ret :: proc(emitter: ^Emitter) {
	emit_byte(emitter, 0xC3)
}

ret_imm :: proc(emitter: ^Emitter, imm: u16) {
	emit_byte(emitter, 0xC2)
	emit_u16(emitter, imm)
}

push_reg :: proc(emitter: ^Emitter, src: Reg) {
	assert_gpr(src)
	assert(reg_width(src) == .Qword, "push operand must be 64-bit")
	emit_op_plus_reg(emitter, 0x50, reg_index(src), false, false)
}

pop_reg :: proc(emitter: ^Emitter, dst: Reg) {
	assert_gpr(dst)
	assert(reg_width(dst) == .Qword, "pop operand must be 64-bit")
	emit_op_plus_reg(emitter, 0x58, reg_index(dst), false, false)
}

push_imm :: proc(emitter: ^Emitter, imm: i32) {
	if imm >= -128 && imm <= 127 {
		emit_byte(emitter, 0x6A)
		emit_byte(emitter, byte(imm))
		return
	}
	emit_byte(emitter, 0x68)
	emit_u32(emitter, u32(imm))
}

push_mem :: proc(emitter: ^Emitter, src: Mem) {
	emit_reg_mem(emitter, Opcode_Form{opcode = 0xFF}, 6, src, .Qword)
}

pop_mem :: proc(emitter: ^Emitter, dst: Mem) {
	emit_reg_mem(emitter, Opcode_Form{opcode = 0x8F}, 0, dst, .Qword)
}

syscall :: proc(emitter: ^Emitter) {
	emit_byte(emitter, 0x0F)
	emit_byte(emitter, 0x05)
}

ud2 :: proc(emitter: ^Emitter) {
	emit_byte(emitter, 0x0F)
	emit_byte(emitter, 0x0B)
}

int3 :: proc(emitter: ^Emitter) {
	emit_byte(emitter, 0xCC)
}

nop :: proc(emitter: ^Emitter) {
	emit_byte(emitter, 0x90)
}

@(private)
sse_reg_reg :: proc(emitter: ^Emitter, prefix, opcode: u8, reg_field, rm_reg: Reg, rex_w: bool) {
	emit_reg_reg(emitter, Opcode_Form{mandatory_prefix = prefix, opcode = opcode, two_byte = true, rex_w = rex_w}, reg_index(reg_field), reg_index(rm_reg), .Dword)
}

@(private)
sse_reg_mem :: proc(emitter: ^Emitter, prefix, opcode: u8, reg_field: Reg, mem: Mem, rex_w: bool) {
	emit_reg_mem(emitter, Opcode_Form{mandatory_prefix = prefix, opcode = opcode, two_byte = true, rex_w = rex_w}, reg_index(reg_field), mem, .Dword)
}

movss_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0xF3, 0x10, dst, src, false)
}

movss_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0xF3, 0x10, dst, src, false)
}

movss_mem_reg :: proc(emitter: ^Emitter, dst: Mem, src: Reg) {
	assert_xmm(src)
	sse_reg_mem(emitter, 0xF3, 0x11, src, dst, false)
}

movsd_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0xF2, 0x10, dst, src, false)
}

movsd_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0xF2, 0x10, dst, src, false)
}

movsd_mem_reg :: proc(emitter: ^Emitter, dst: Mem, src: Reg) {
	assert_xmm(src)
	sse_reg_mem(emitter, 0xF2, 0x11, src, dst, false)
}

addss_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0xF3, 0x58, dst, src, false)
}

addss_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0xF3, 0x58, dst, src, false)
}

addsd_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0xF2, 0x58, dst, src, false)
}

addsd_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0xF2, 0x58, dst, src, false)
}

subss_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0xF3, 0x5C, dst, src, false)
}

subss_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0xF3, 0x5C, dst, src, false)
}

subsd_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0xF2, 0x5C, dst, src, false)
}

subsd_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0xF2, 0x5C, dst, src, false)
}

mulss_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0xF3, 0x59, dst, src, false)
}

mulss_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0xF3, 0x59, dst, src, false)
}

mulsd_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0xF2, 0x59, dst, src, false)
}

mulsd_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0xF2, 0x59, dst, src, false)
}

divss_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0xF3, 0x5E, dst, src, false)
}

divss_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0xF3, 0x5E, dst, src, false)
}

divsd_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0xF2, 0x5E, dst, src, false)
}

divsd_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0xF2, 0x5E, dst, src, false)
}

ucomiss_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0, 0x2E, dst, src, false)
}

ucomiss_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0, 0x2E, dst, src, false)
}

ucomisd_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	assert_xmm(dst)
	assert_xmm(src)
	sse_reg_reg(emitter, 0x66, 0x2E, dst, src, false)
}

ucomisd_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_xmm(dst)
	sse_reg_mem(emitter, 0x66, 0x2E, dst, src, false)
}

cvtsi2ss_reg_reg :: proc(emitter: ^Emitter, dst: Reg, src: Reg) {
	assert_xmm(dst)
	assert_gpr(src)
	width := reg_width(src)
	assert(width == .Dword || width == .Qword, "cvtsi2ss source must be 32 or 64-bit")
	sse_reg_reg(emitter, 0xF3, 0x2A, dst, src, width == .Qword)
}

cvtsi2ss_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem, src_width: Reg_Width) {
	assert_xmm(dst)
	assert(src_width == .Dword || src_width == .Qword, "cvtsi2ss source must be 32 or 64-bit")
	sse_reg_mem(emitter, 0xF3, 0x2A, dst, src, src_width == .Qword)
}

cvtsi2sd_reg_reg :: proc(emitter: ^Emitter, dst: Reg, src: Reg) {
	assert_xmm(dst)
	assert_gpr(src)
	width := reg_width(src)
	assert(width == .Dword || width == .Qword, "cvtsi2sd source must be 32 or 64-bit")
	sse_reg_reg(emitter, 0xF2, 0x2A, dst, src, width == .Qword)
}

cvtsi2sd_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem, src_width: Reg_Width) {
	assert_xmm(dst)
	assert(src_width == .Dword || src_width == .Qword, "cvtsi2sd source must be 32 or 64-bit")
	sse_reg_mem(emitter, 0xF2, 0x2A, dst, src, src_width == .Qword)
}

cvttss2si_reg_reg :: proc(emitter: ^Emitter, dst: Reg, src: Reg) {
	assert_gpr(dst)
	assert_xmm(src)
	width := reg_width(dst)
	assert(width == .Dword || width == .Qword, "cvttss2si destination must be 32 or 64-bit")
	sse_reg_reg(emitter, 0xF3, 0x2C, dst, src, width == .Qword)
}

cvttss2si_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	width := reg_width(dst)
	assert(width == .Dword || width == .Qword, "cvttss2si destination must be 32 or 64-bit")
	sse_reg_mem(emitter, 0xF3, 0x2C, dst, src, width == .Qword)
}

cvttsd2si_reg_reg :: proc(emitter: ^Emitter, dst: Reg, src: Reg) {
	assert_gpr(dst)
	assert_xmm(src)
	width := reg_width(dst)
	assert(width == .Dword || width == .Qword, "cvttsd2si destination must be 32 or 64-bit")
	sse_reg_reg(emitter, 0xF2, 0x2C, dst, src, width == .Qword)
}

cvttsd2si_reg_mem :: proc(emitter: ^Emitter, dst: Reg, src: Mem) {
	assert_gpr(dst)
	width := reg_width(dst)
	assert(width == .Dword || width == .Qword, "cvttsd2si destination must be 32 or 64-bit")
	sse_reg_mem(emitter, 0xF2, 0x2C, dst, src, width == .Qword)
}

// The transfer direction follows the operand classes: only one operand may be
// an XMM register.
movq_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	if reg_class(dst) == .Vector {
		assert_xmm(dst)
		assert_gpr(src)
		assert(reg_width(src) == .Qword, "movq GPR operand must be 64-bit")
		sse_reg_reg(emitter, 0x66, 0x6E, dst, src, true)
		return
	}
	assert_gpr(dst)
	assert_xmm(src)
	assert(reg_width(dst) == .Qword, "movq GPR operand must be 64-bit")
	sse_reg_reg(emitter, 0x66, 0x7E, src, dst, true)
}

movd_reg_reg :: proc(emitter: ^Emitter, dst, src: Reg) {
	if reg_class(dst) == .Vector {
		assert_xmm(dst)
		assert_gpr(src)
		assert(reg_width(src) == .Dword, "movd GPR operand must be 32-bit")
		sse_reg_reg(emitter, 0x66, 0x6E, dst, src, false)
		return
	}
	assert_gpr(dst)
	assert_xmm(src)
	assert(reg_width(dst) == .Dword, "movd GPR operand must be 32-bit")
	sse_reg_reg(emitter, 0x66, 0x7E, src, dst, false)
}

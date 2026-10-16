package x64

import "core:mem"
import "core:slice"
import "core:testing"

// The expected byte sequences in this file were produced by assembling the
// same instruction with the GNU/LLVM assemblers and reading back the encoding
// (llvm-mc -show-encoding, cross-checked with as/objdump). Every special case
// the encoder handles appears here: REX for the dedicated 8-bit registers,
// SIB for RSP/R12 bases, the mandatory disp8 for RBP/R13 bases, R12 as an
// index, RIP-relative and absolute addressing, and index-only forms.

@(private)
expect_bytes :: proc(t: ^testing.T, e: ^Emitter, want: []byte, loc := #caller_location) {
	testing.expectf(t, slice.equal(e.code[:], want), "got %v, want %v", e.code[:], want, loc = loc)
}

@(private)
mem_base :: proc(base: Reg, disp: i32) -> Mem {
	return Mem{base = base, disp = disp}
}

@(private)
mem_base_index :: proc(base, index: Reg, scale: u8, disp: i32) -> Mem {
	return Mem{base = base, index = index, scale = scale, disp = disp}
}

@(private)
mem_index :: proc(index: Reg, scale: u8, disp: i32) -> Mem {
	return Mem{index = index, scale = scale, disp = disp}
}

@(private)
mem_rip :: proc(disp: i32) -> Mem {
	return Mem{disp = disp, flags = {.Rip_Relative}}
}

@(private)
mem_abs :: proc(disp: i32) -> Mem {
	return Mem{disp = disp}
}

// Bin_Op lets one table drive every binary ALU mnemonic.
@(private)
Bin_Op :: enum {
	Add,
	Sub,
	And,
	Or,
	Xor,
	Cmp,
}

@(private)
bin_reg_reg :: proc(e: ^Emitter, op: Bin_Op, dst, src: Reg) {
	switch op {
	case .Add: add_reg_reg(e, dst, src)
	case .Sub: sub_reg_reg(e, dst, src)
	case .And: and_reg_reg(e, dst, src)
	case .Or:  or_reg_reg(e, dst, src)
	case .Xor: xor_reg_reg(e, dst, src)
	case .Cmp: cmp_reg_reg(e, dst, src)
	}
}

@(private)
bin_reg_mem :: proc(e: ^Emitter, op: Bin_Op, dst: Reg, src: Mem) {
	switch op {
	case .Add: add_reg_mem(e, dst, src)
	case .Sub: sub_reg_mem(e, dst, src)
	case .And: and_reg_mem(e, dst, src)
	case .Or:  or_reg_mem(e, dst, src)
	case .Xor: xor_reg_mem(e, dst, src)
	case .Cmp: cmp_reg_mem(e, dst, src)
	}
}

@(private)
bin_mem_reg :: proc(e: ^Emitter, op: Bin_Op, dst: Mem, src: Reg) {
	switch op {
	case .Add: add_mem_reg(e, dst, src)
	case .Sub: sub_mem_reg(e, dst, src)
	case .And: and_mem_reg(e, dst, src)
	case .Or:  or_mem_reg(e, dst, src)
	case .Xor: xor_mem_reg(e, dst, src)
	case .Cmp: cmp_mem_reg(e, dst, src)
	}
}

@(private)
bin_reg_imm :: proc(e: ^Emitter, op: Bin_Op, dst: Reg, imm: i64) {
	switch op {
	case .Add: add_reg_imm(e, dst, imm)
	case .Sub: sub_reg_imm(e, dst, imm)
	case .And: and_reg_imm(e, dst, imm)
	case .Or:  or_reg_imm(e, dst, imm)
	case .Xor: xor_reg_imm(e, dst, imm)
	case .Cmp: cmp_reg_imm(e, dst, imm)
	}
}

@(test)
test_mov_reg_reg :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	cases := []struct {
		dst, src: Reg,
		want:     []byte,
	}{
		{RAX, RBX, []byte{0x48, 0x89, 0xd8}},
		{RCX, RDX, []byte{0x48, 0x89, 0xd1}},
		{RSP, RBP, []byte{0x48, 0x89, 0xec}},
		{R12, R13, []byte{0x4d, 0x89, 0xec}},
		{EAX, EBX, []byte{0x89, 0xd8}},
		{ESP, EBP, []byte{0x89, 0xec}},
		{AX, BX, []byte{0x66, 0x89, 0xd8}},
		{SP, BP, []byte{0x66, 0x89, 0xec}},
		{AL, BL, []byte{0x88, 0xd8}},
		{SPL, BPL, []byte{0x40, 0x88, 0xec}},
		{SIL, DIL, []byte{0x40, 0x88, 0xfe}},
		{R8B, R15B, []byte{0x45, 0x88, 0xf8}},
		{R8, R15, []byte{0x4d, 0x89, 0xf8}},
		{R8D, R15D, []byte{0x45, 0x89, 0xf8}},
		{R8W, R15W, []byte{0x66, 0x45, 0x89, 0xf8}},
	}
	for c in cases {
		emitter_reset(&e)
		mov_reg_reg(&e, c.dst, c.src)
		expect_bytes(t, &e, c.want)
	}
}

@(test)
test_mov_mem :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	loads := []struct {
		dst:  Reg,
		src:  Mem,
		want: []byte,
	}{
		{RAX, mem_base(RSP, 0), []byte{0x48, 0x8b, 0x04, 0x24}},
		{RAX, mem_base(R12, 0), []byte{0x49, 0x8b, 0x04, 0x24}},
		{RAX, mem_base(RBP, 0), []byte{0x48, 0x8b, 0x45, 0x00}},
		{RAX, mem_base(R13, 0), []byte{0x49, 0x8b, 0x45, 0x00}},
		{RAX, mem_base(RBP, 8), []byte{0x48, 0x8b, 0x45, 0x08}},
		{RAX, mem_base(RBP, 0x1234), []byte{0x48, 0x8b, 0x85, 0x34, 0x12, 0x00, 0x00}},
		{RAX, mem_base_index(RSP, RAX, 4, 0), []byte{0x48, 0x8b, 0x04, 0x84}},
		{RAX, mem_base_index(RAX, RBX, 2, 0), []byte{0x48, 0x8b, 0x04, 0x58}},
		{RAX, mem_base_index(RBX, R12, 2, 0), []byte{0x4a, 0x8b, 0x04, 0x63}},
		{RAX, mem_base_index(R12, RBX, 8, 0x10), []byte{0x49, 0x8b, 0x44, 0xdc, 0x10}},
		{RAX, mem_base(RBP, -8), []byte{0x48, 0x8b, 0x45, 0xf8}},
		{RAX, mem_base(RAX, -0x1234), []byte{0x48, 0x8b, 0x80, 0xcc, 0xed, 0xff, 0xff}},
		{RAX, mem_base(R13, -8), []byte{0x49, 0x8b, 0x45, 0xf8}},
		{RAX, mem_base(R12, -0x80), []byte{0x49, 0x8b, 0x44, 0x24, 0x80}},
		{RAX, mem_base_index(RBX, R12, 4, -16), []byte{0x4a, 0x8b, 0x44, 0xa3, 0xf0}},
		{RAX, mem_rip(0x1234), []byte{0x48, 0x8b, 0x05, 0x34, 0x12, 0x00, 0x00}},
		{RAX, mem_abs(0x12345678), []byte{0x48, 0x8b, 0x04, 0x25, 0x78, 0x56, 0x34, 0x12}},
		{RAX, mem_index(RAX, 8, 0x10), []byte{0x48, 0x8b, 0x04, 0xc5, 0x10, 0x00, 0x00, 0x00}},
		{R8, mem_base(R15, 0x10), []byte{0x4d, 0x8b, 0x47, 0x10}},
	}
	for c in loads {
		emitter_reset(&e)
		mov_reg_mem(&e, c.dst, c.src)
		expect_bytes(t, &e, c.want)
	}

	stores := []struct {
		dst:  Mem,
		src:  Reg,
		want: []byte,
	}{
		{mem_base(RSP, 0), EAX, []byte{0x89, 0x04, 0x24}},
		{mem_base(RBP, 0), RBX, []byte{0x48, 0x89, 0x5d, 0x00}},
		{mem_base_index(RBX, R12, 2, 0), R15, []byte{0x4e, 0x89, 0x3c, 0x63}},
		{mem_base(RSP, 8), AL, []byte{0x88, 0x44, 0x24, 0x08}},
		{mem_base(RSP, 8), SIL, []byte{0x40, 0x88, 0x74, 0x24, 0x08}},
		{mem_base(RBP, -8), RBX, []byte{0x48, 0x89, 0x5d, 0xf8}},
	}
	for c in stores {
		emitter_reset(&e)
		mov_mem_reg(&e, c.dst, c.src)
		expect_bytes(t, &e, c.want)
	}
}

@(test)
test_mov_imm :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	cases := []struct {
		dst:  Reg,
		imm:  i64,
		want: []byte,
	}{
		{AL, 0x7f, []byte{0xb0, 0x7f}},
		{CL, 0x80, []byte{0xb1, 0x80}},
		{AX, 0x1234, []byte{0x66, 0xb8, 0x34, 0x12}},
		{CX, 0x1234, []byte{0x66, 0xb9, 0x34, 0x12}},
		{EAX, 0x11223344, []byte{0xb8, 0x44, 0x33, 0x22, 0x11}},
		{ECX, 0x11223344, []byte{0xb9, 0x44, 0x33, 0x22, 0x11}},
		{RCX, 0x1234, []byte{0x48, 0xc7, 0xc1, 0x34, 0x12, 0x00, 0x00}},
	}
	for c in cases {
		emitter_reset(&e)
		mov_reg_imm(&e, c.dst, c.imm)
		expect_bytes(t, &e, c.want)
	}

	emitter_reset(&e)
	movabs_reg_imm64(&e, RAX, 0x1122334455667788)
	expect_bytes(t, &e, {0x48, 0xb8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11})

	emitter_reset(&e)
	movabs_reg_imm64(&e, R8, 0x1122334455667788)
	expect_bytes(t, &e, {0x49, 0xb8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11})

	// mov_reg_imm selects movabs for a 64-bit immediate outside the i32 range.
	emitter_reset(&e)
	mov_reg_imm(&e, RAX, 0x1122334455667788)
	expect_bytes(t, &e, {0x48, 0xb8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11})
}

@(test)
test_movx :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	rr := []struct {
		dst, src: Reg,
		want:     []byte,
	}{
		{EAX, BL, []byte{0x0f, 0xb6, 0xc3}},
		{RAX, BL, []byte{0x48, 0x0f, 0xb6, 0xc3}},
		{R8D, R15B, []byte{0x45, 0x0f, 0xb6, 0xc7}},
		{EAX, BX, []byte{0x0f, 0xb7, 0xc3}},
		{RAX, BX, []byte{0x48, 0x0f, 0xb7, 0xc3}},
	}
	for c in rr {
		emitter_reset(&e)
		movzx_reg_reg(&e, c.dst, c.src)
		expect_bytes(t, &e, c.want)
	}

	emitter_reset(&e)
	movzx_reg_mem(&e, EAX, mem_base(RSP, 8), .Byte)
	expect_bytes(t, &e, {0x0f, 0xb6, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	movzx_reg_mem(&e, RAX, mem_base(RSP, 8), .Word)
	expect_bytes(t, &e, {0x48, 0x0f, 0xb7, 0x44, 0x24, 0x08})

	sx := []struct {
		dst, src: Reg,
		want:     []byte,
	}{
		{EAX, BL, []byte{0x0f, 0xbe, 0xc3}},
		{RAX, BL, []byte{0x48, 0x0f, 0xbe, 0xc3}},
		{RAX, BX, []byte{0x48, 0x0f, 0xbf, 0xc3}},
	}
	for c in sx {
		emitter_reset(&e)
		movsx_reg_reg(&e, c.dst, c.src)
		expect_bytes(t, &e, c.want)
	}

	emitter_reset(&e)
	movsx_reg_mem(&e, EAX, mem_base(RSP, 8), .Byte)
	expect_bytes(t, &e, {0x0f, 0xbe, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	movsxd_reg_reg(&e, RAX, EBX)
	expect_bytes(t, &e, {0x48, 0x63, 0xc3})

	emitter_reset(&e)
	movsxd_reg_mem(&e, RAX, mem_base(RSP, 8))
	expect_bytes(t, &e, {0x48, 0x63, 0x44, 0x24, 0x08})
}

@(test)
test_lea :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	lea_reg_mem(&e, RAX, mem_base(RSP, 8))
	expect_bytes(t, &e, {0x48, 0x8d, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	lea_reg_mem(&e, R8, mem_base_index(RBX, R12, 2, 0x10))
	expect_bytes(t, &e, {0x4e, 0x8d, 0x44, 0x63, 0x10})

	emitter_reset(&e)
	lea_reg_mem(&e, EAX, mem_rip(0x100))
	expect_bytes(t, &e, {0x8d, 0x05, 0x00, 0x01, 0x00, 0x00})
}

@(test)
test_alu_reg_reg :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	cases := []struct {
		op:       Bin_Op,
		dst, src: Reg,
		want:     []byte,
	}{
		{.Add, RAX, RBX, []byte{0x48, 0x01, 0xd8}},
		{.Add, R8, R15, []byte{0x4d, 0x01, 0xf8}},
		{.Add, ECX, EBX, []byte{0x01, 0xd9}},
		{.Add, CX, BX, []byte{0x66, 0x01, 0xd9}},
		{.Add, BL, CL, []byte{0x00, 0xcb}},
		{.Sub, RCX, RDX, []byte{0x48, 0x29, 0xd1}},
		{.And, RCX, RDX, []byte{0x48, 0x21, 0xd1}},
		{.Or, RCX, RDX, []byte{0x48, 0x09, 0xd1}},
		{.Xor, RCX, RDX, []byte{0x48, 0x31, 0xd1}},
		{.Cmp, RCX, RDX, []byte{0x48, 0x39, 0xd1}},
	}
	for c in cases {
		emitter_reset(&e)
		bin_reg_reg(&e, c.op, c.dst, c.src)
		expect_bytes(t, &e, c.want)
	}

	emitter_reset(&e)
	bin_reg_mem(&e, .Add, RAX, mem_base(RSP, 8))
	expect_bytes(t, &e, {0x48, 0x03, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	bin_mem_reg(&e, .Add, mem_base(RSP, 8), RAX)
	expect_bytes(t, &e, {0x48, 0x01, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	bin_mem_reg(&e, .Add, mem_base(RBP, -8), RBX)
	expect_bytes(t, &e, {0x48, 0x01, 0x5d, 0xf8})
}

@(test)
test_alu_reg_imm :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	cases := []struct {
		op:   Bin_Op,
		dst:  Reg,
		imm:  i64,
		want: []byte,
	}{
		{.Add, RBX, 0x1234, []byte{0x48, 0x81, 0xc3, 0x34, 0x12, 0x00, 0x00}},
		{.Add, RBX, 0x7f, []byte{0x48, 0x83, 0xc3, 0x7f}},
		{.Add, EBX, 0x1234, []byte{0x81, 0xc3, 0x34, 0x12, 0x00, 0x00}},
		{.Add, BX, 0x7f, []byte{0x66, 0x83, 0xc3, 0x7f}},
		{.Add, BL, 0x7f, []byte{0x80, 0xc3, 0x7f}},
		{.Cmp, RCX, 0x7f, []byte{0x48, 0x83, 0xf9, 0x7f}},
	}
	for c in cases {
		emitter_reset(&e)
		bin_reg_imm(&e, c.op, c.dst, c.imm)
		expect_bytes(t, &e, c.want)
	}
}

@(test)
test_test :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	test_reg_reg(&e, RCX, RDX)
	expect_bytes(t, &e, {0x48, 0x85, 0xd1})

	emitter_reset(&e)
	test_reg_reg(&e, RDX, RCX)
	expect_bytes(t, &e, {0x48, 0x85, 0xca})

	emitter_reset(&e)
	test_reg_mem(&e, RCX, mem_base(RSP, 8))
	expect_bytes(t, &e, {0x48, 0x85, 0x4c, 0x24, 0x08})

	emitter_reset(&e)
	test_mem_reg(&e, mem_base(RSP, 8), RCX)
	expect_bytes(t, &e, {0x48, 0x85, 0x4c, 0x24, 0x08})

	emitter_reset(&e)
	test_reg_imm(&e, RCX, 0x7f)
	expect_bytes(t, &e, {0x48, 0xf7, 0xc1, 0x7f, 0x00, 0x00, 0x00})

	emitter_reset(&e)
	test_reg_imm(&e, BL, 0x7f)
	expect_bytes(t, &e, {0xf6, 0xc3, 0x7f})
}

@(test)
test_imul_div_neg :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	imul_reg_reg(&e, RCX, RDX)
	expect_bytes(t, &e, {0x48, 0x0f, 0xaf, 0xca})

	emitter_reset(&e)
	imul_reg_reg(&e, R8, R15)
	expect_bytes(t, &e, {0x4d, 0x0f, 0xaf, 0xc7})

	emitter_reset(&e)
	imul_reg_reg(&e, ECX, EDX)
	expect_bytes(t, &e, {0x0f, 0xaf, 0xca})

	emitter_reset(&e)
	imul_reg_mem(&e, RCX, mem_base(RSP, 8))
	expect_bytes(t, &e, {0x48, 0x0f, 0xaf, 0x4c, 0x24, 0x08})

	emitter_reset(&e)
	imul_reg_reg_imm(&e, RCX, RDX, 0x10)
	expect_bytes(t, &e, {0x48, 0x6b, 0xca, 0x10})

	emitter_reset(&e)
	imul_reg_reg_imm(&e, RCX, RDX, 0x1234)
	expect_bytes(t, &e, {0x48, 0x69, 0xca, 0x34, 0x12, 0x00, 0x00})

	emitter_reset(&e)
	idiv_reg(&e, RCX)
	expect_bytes(t, &e, {0x48, 0xf7, 0xf9})

	emitter_reset(&e)
	idiv_reg(&e, R8)
	expect_bytes(t, &e, {0x49, 0xf7, 0xf8})

	emitter_reset(&e)
	div_reg(&e, ECX)
	expect_bytes(t, &e, {0xf7, 0xf1})

	emitter_reset(&e)
	neg_reg(&e, RCX)
	expect_bytes(t, &e, {0x48, 0xf7, 0xd9})

	emitter_reset(&e)
	not_reg(&e, RCX)
	expect_bytes(t, &e, {0x48, 0xf7, 0xd1})
}

@(test)
test_shifts :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	shl_reg_imm(&e, RCX, 5)
	expect_bytes(t, &e, {0x48, 0xc1, 0xe1, 0x05})

	emitter_reset(&e)
	shr_reg_imm(&e, RCX, 3)
	expect_bytes(t, &e, {0x48, 0xc1, 0xe9, 0x03})

	emitter_reset(&e)
	sar_reg_imm(&e, RCX, 3)
	expect_bytes(t, &e, {0x48, 0xc1, 0xf9, 0x03})

	emitter_reset(&e)
	shl_reg_cl(&e, RCX)
	expect_bytes(t, &e, {0x48, 0xd3, 0xe1})

	emitter_reset(&e)
	sar_reg_cl(&e, R8)
	expect_bytes(t, &e, {0x49, 0xd3, 0xf8})

	emitter_reset(&e)
	shl_mem_imm(&e, mem_base(RSP, 8), 5, .Byte)
	expect_bytes(t, &e, {0xc0, 0x64, 0x24, 0x08, 0x05})

	emitter_reset(&e)
	shr_mem_cl(&e, mem_base(RSP, 8), .Qword)
	expect_bytes(t, &e, {0x48, 0xd3, 0x6c, 0x24, 0x08})
}

@(test)
test_setcc_cmovcc :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	setcc_reg(&e, .Equal, AL)
	expect_bytes(t, &e, {0x0f, 0x94, 0xc0})

	emitter_reset(&e)
	setcc_reg(&e, .Not_Equal, R8B)
	expect_bytes(t, &e, {0x41, 0x0f, 0x95, 0xc0})

	emitter_reset(&e)
	setcc_reg(&e, .Below, BL)
	expect_bytes(t, &e, {0x0f, 0x92, 0xc3})

	emitter_reset(&e)
	setcc_reg(&e, .Greater, DL)
	expect_bytes(t, &e, {0x0f, 0x9f, 0xc2})

	emitter_reset(&e)
	setcc_mem(&e, .Less, mem_base(RSP, 8))
	expect_bytes(t, &e, {0x0f, 0x9c, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	setcc_reg(&e, .Greater, SIL)
	expect_bytes(t, &e, {0x40, 0x0f, 0x9f, 0xc6})

	emitter_reset(&e)
	cmovcc_reg_reg(&e, .Equal, RAX, RBX)
	expect_bytes(t, &e, {0x48, 0x0f, 0x44, 0xc3})

	emitter_reset(&e)
	cmovcc_reg_reg(&e, .Not_Equal, R8, R15)
	expect_bytes(t, &e, {0x4d, 0x0f, 0x45, 0xc7})

	emitter_reset(&e)
	cmovcc_reg_reg(&e, .Less, ECX, EDX)
	expect_bytes(t, &e, {0x0f, 0x4c, 0xca})

	emitter_reset(&e)
	cmovcc_reg_mem(&e, .Greater, RCX, mem_base(RSP, 8))
	expect_bytes(t, &e, {0x48, 0x0f, 0x4f, 0x4c, 0x24, 0x08})
}

@(test)
test_misc :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	cqo(&e)
	expect_bytes(t, &e, {0x48, 0x99})

	emitter_reset(&e)
	cdq(&e)
	expect_bytes(t, &e, {0x99})

	emitter_reset(&e)
	syscall(&e)
	expect_bytes(t, &e, {0x0f, 0x05})

	emitter_reset(&e)
	ud2(&e)
	expect_bytes(t, &e, {0x0f, 0x0b})

	emitter_reset(&e)
	int3(&e)
	expect_bytes(t, &e, {0xcc})

	emitter_reset(&e)
	nop(&e)
	expect_bytes(t, &e, {0x90})

	emitter_reset(&e)
	ret(&e)
	expect_bytes(t, &e, {0xc3})

	emitter_reset(&e)
	ret_imm(&e, 0x10)
	expect_bytes(t, &e, {0xc2, 0x10, 0x00})
}

@(test)
test_push_pop :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	reg_cases := []struct {
		r:    Reg,
		push: []byte,
		pop:  []byte,
	}{
		{RCX, []byte{0x51}, []byte{0x59}},
		{R15, []byte{0x41, 0x57}, []byte{0x41, 0x5f}},
	}
	for c in reg_cases {
		emitter_reset(&e)
		push_reg(&e, c.r)
		expect_bytes(t, &e, c.push)

		emitter_reset(&e)
		pop_reg(&e, c.r)
		expect_bytes(t, &e, c.pop)
	}

	emitter_reset(&e)
	push_mem(&e, mem_base(RSP, 8))
	expect_bytes(t, &e, {0xff, 0x74, 0x24, 0x08})

	emitter_reset(&e)
	pop_mem(&e, mem_base(RSP, 8))
	expect_bytes(t, &e, {0x8f, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	push_imm(&e, 0x7f)
	expect_bytes(t, &e, {0x6a, 0x7f})

	emitter_reset(&e)
	push_imm(&e, 0x12345678)
	expect_bytes(t, &e, {0x68, 0x78, 0x56, 0x34, 0x12})
}

@(test)
test_indirect_jumps :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	jmp_reg(&e, RCX)
	expect_bytes(t, &e, {0xff, 0xe1})

	emitter_reset(&e)
	jmp_reg(&e, R8)
	expect_bytes(t, &e, {0x41, 0xff, 0xe0})

	emitter_reset(&e)
	jmp_mem(&e, mem_base(RSP, 8))
	expect_bytes(t, &e, {0xff, 0x64, 0x24, 0x08})

	emitter_reset(&e)
	call_reg(&e, RCX)
	expect_bytes(t, &e, {0xff, 0xd1})

	emitter_reset(&e)
	call_reg(&e, R8)
	expect_bytes(t, &e, {0x41, 0xff, 0xd0})

	emitter_reset(&e)
	call_mem(&e, mem_base(RSP, 8))
	expect_bytes(t, &e, {0xff, 0x54, 0x24, 0x08})
}

@(test)
test_labels :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	// jmp L0; nop; L0: ret; L1: je L1; call L0
	l0 := label_new(&e)
	l1 := label_new(&e)
	jmp_label(&e, l0)         // offset 0: E9 + rel32 field at 1
	nop(&e)                   // offset 5
	label_bind(&e, l0)        // offset 6
	ret(&e)                   // offset 6
	label_bind(&e, l1)        // offset 7
	jcc_label(&e, .Equal, l1) // offset 7: 0F 84 + rel32 field at 9
	call_label(&e, l0)        // offset 13: E8 + rel32 field at 14
	label_resolve(&e)

	// rel32 fields: L0 -> 6, L1 -> 7.
	//   field at 1:  6  - (1  + 4) =   1
	//   field at 9:  7  - (9  + 4) =  -6
	//   field at 14: 6  - (14 + 4) = -12
	expect_bytes(
		t,
		&e,
		{
			0xe9, 0x01, 0x00, 0x00, 0x00,
			0x90,
			0xc3,
			0x0f, 0x84, 0xfa, 0xff, 0xff, 0xff,
			0xe8, 0xf4, 0xff, 0xff, 0xff,
		},
	)

	off, ok := label_offset(&e, l0)
	testing.expect(t, ok && off == 6, "label_offset(L0)")
	_, ok = label_offset(&e, label_new(&e))
	testing.expect(t, !ok, "unbound label has no offset")
}

@(test)
test_sse_mov :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	movss_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0xf3, 0x0f, 0x10, 0xc1})

	emitter_reset(&e)
	movss_reg_reg(&e, XMM8, XMM15)
	expect_bytes(t, &e, {0xf3, 0x45, 0x0f, 0x10, 0xc7})

	emitter_reset(&e)
	movss_reg_mem(&e, XMM0, mem_base(RSP, 8))
	expect_bytes(t, &e, {0xf3, 0x0f, 0x10, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	movss_mem_reg(&e, mem_base(RSP, 8), XMM0)
	expect_bytes(t, &e, {0xf3, 0x0f, 0x11, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	movsd_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0xf2, 0x0f, 0x10, 0xc1})

	emitter_reset(&e)
	movsd_reg_mem(&e, XMM0, mem_base(RSP, 8))
	expect_bytes(t, &e, {0xf2, 0x0f, 0x10, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	movsd_mem_reg(&e, mem_base(RSP, 8), XMM0)
	expect_bytes(t, &e, {0xf2, 0x0f, 0x11, 0x44, 0x24, 0x08})
}

@(test)
test_sse_arith :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	addss_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0xf3, 0x0f, 0x58, 0xc1})

	emitter_reset(&e)
	addsd_reg_reg(&e, XMM8, XMM15)
	expect_bytes(t, &e, {0xf2, 0x45, 0x0f, 0x58, 0xc7})

	emitter_reset(&e)
	addss_reg_mem(&e, XMM0, mem_base(RSP, 8))
	expect_bytes(t, &e, {0xf3, 0x0f, 0x58, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	subss_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0xf3, 0x0f, 0x5c, 0xc1})

	emitter_reset(&e)
	subsd_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0xf2, 0x0f, 0x5c, 0xc1})

	emitter_reset(&e)
	mulss_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0xf3, 0x0f, 0x59, 0xc1})

	emitter_reset(&e)
	mulsd_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0xf2, 0x0f, 0x59, 0xc1})

	emitter_reset(&e)
	divss_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0xf3, 0x0f, 0x5e, 0xc1})

	emitter_reset(&e)
	divsd_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0xf2, 0x0f, 0x5e, 0xc1})
}

@(test)
test_sse_compare :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	ucomiss_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0x0f, 0x2e, 0xc1})

	emitter_reset(&e)
	ucomisd_reg_reg(&e, XMM0, XMM1)
	expect_bytes(t, &e, {0x66, 0x0f, 0x2e, 0xc1})

	emitter_reset(&e)
	ucomiss_reg_mem(&e, XMM0, mem_base(RSP, 8))
	expect_bytes(t, &e, {0x0f, 0x2e, 0x44, 0x24, 0x08})
}

@(test)
test_sse_convert :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	cvtsi2ss_reg_reg(&e, XMM0, ECX)
	expect_bytes(t, &e, {0xf3, 0x0f, 0x2a, 0xc1})

	emitter_reset(&e)
	cvtsi2ss_reg_reg(&e, XMM0, RCX)
	expect_bytes(t, &e, {0xf3, 0x48, 0x0f, 0x2a, 0xc1})

	emitter_reset(&e)
	cvtsi2sd_reg_reg(&e, XMM0, ECX)
	expect_bytes(t, &e, {0xf2, 0x0f, 0x2a, 0xc1})

	emitter_reset(&e)
	cvtsi2sd_reg_reg(&e, XMM0, RCX)
	expect_bytes(t, &e, {0xf2, 0x48, 0x0f, 0x2a, 0xc1})

	emitter_reset(&e)
	cvtsi2ss_reg_reg(&e, XMM8, R15)
	expect_bytes(t, &e, {0xf3, 0x4d, 0x0f, 0x2a, 0xc7})

	emitter_reset(&e)
	cvtsi2ss_reg_mem(&e, XMM0, mem_base(RSP, 8), .Dword)
	expect_bytes(t, &e, {0xf3, 0x0f, 0x2a, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	cvtsi2ss_reg_mem(&e, XMM0, mem_base(RSP, 8), .Qword)
	expect_bytes(t, &e, {0xf3, 0x48, 0x0f, 0x2a, 0x44, 0x24, 0x08})

	emitter_reset(&e)
	cvttss2si_reg_reg(&e, ECX, XMM0)
	expect_bytes(t, &e, {0xf3, 0x0f, 0x2c, 0xc8})

	emitter_reset(&e)
	cvttss2si_reg_reg(&e, RCX, XMM0)
	expect_bytes(t, &e, {0xf3, 0x48, 0x0f, 0x2c, 0xc8})

	emitter_reset(&e)
	cvttsd2si_reg_reg(&e, ECX, XMM0)
	expect_bytes(t, &e, {0xf2, 0x0f, 0x2c, 0xc8})

	emitter_reset(&e)
	cvttsd2si_reg_reg(&e, RCX, XMM0)
	expect_bytes(t, &e, {0xf2, 0x48, 0x0f, 0x2c, 0xc8})

	emitter_reset(&e)
	cvttss2si_reg_reg(&e, R8, XMM15)
	expect_bytes(t, &e, {0xf3, 0x4d, 0x0f, 0x2c, 0xc7})

	emitter_reset(&e)
	cvttss2si_reg_mem(&e, ECX, mem_base(RSP, 8))
	expect_bytes(t, &e, {0xf3, 0x0f, 0x2c, 0x4c, 0x24, 0x08})

	emitter_reset(&e)
	cvttss2si_reg_mem(&e, RCX, mem_base(RSP, 8))
	expect_bytes(t, &e, {0xf3, 0x48, 0x0f, 0x2c, 0x4c, 0x24, 0x08})
}

@(test)
test_sse_gpr :: proc(t: ^testing.T) {
	e: Emitter
	emitter_init(&e)
	defer emitter_destroy(&e)

	emitter_reset(&e)
	movq_reg_reg(&e, XMM0, RCX)
	expect_bytes(t, &e, {0x66, 0x48, 0x0f, 0x6e, 0xc1})

	emitter_reset(&e)
	movq_reg_reg(&e, RCX, XMM0)
	expect_bytes(t, &e, {0x66, 0x48, 0x0f, 0x7e, 0xc1})

	emitter_reset(&e)
	movq_reg_reg(&e, XMM8, R15)
	expect_bytes(t, &e, {0x66, 0x4d, 0x0f, 0x6e, 0xc7})

	emitter_reset(&e)
	movq_reg_reg(&e, R15, XMM8)
	expect_bytes(t, &e, {0x66, 0x4d, 0x0f, 0x7e, 0xc7})

	emitter_reset(&e)
	movd_reg_reg(&e, XMM0, ECX)
	expect_bytes(t, &e, {0x66, 0x0f, 0x6e, 0xc1})

	emitter_reset(&e)
	movd_reg_reg(&e, ECX, XMM0)
	expect_bytes(t, &e, {0x66, 0x0f, 0x7e, 0xc1})

	emitter_reset(&e)
	movd_reg_reg(&e, XMM8, R15D)
	expect_bytes(t, &e, {0x66, 0x45, 0x0f, 0x6e, 0xc7})

	emitter_reset(&e)
	movd_reg_reg(&e, R15D, XMM8)
	expect_bytes(t, &e, {0x66, 0x45, 0x0f, 0x7e, 0xc7})
}

@(test)
test_emitter_allocator :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	e: Emitter
	emitter_init(&e, mem.tracking_allocator(&track))
	for _ in 0 ..< 64 {
		mov_reg_reg(&e, RAX, RBX)
	}
	testing.expect(t, len(e.code) == 64 * 3, "code length")
	emitter_destroy(&e)

	testing.expectf(t, len(track.allocation_map) == 0, "%v allocations leaked", len(track.allocation_map))
}

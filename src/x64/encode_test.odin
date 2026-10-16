package x64

import "core:mem"
import "core:slice"
import "core:testing"

// Expected byte sequences were produced by assembling the same instructions and
// reading back the encoding (llvm-mc -show-encoding, cross-checked with
// as/objdump).

@(private)
expect_bytes :: proc(t: ^testing.T, emitter: ^Emitter, want: []byte, loc := #caller_location) {
	testing.expectf(t, slice.equal(emitter.code[:], want), "got %v, want %v", emitter.code[:], want, loc = loc)
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

// Covers the ModRM/SIB/displacement special cases: RSP/R12 base needs a SIB
// byte, RBP/R13 base needs a displacement, R12 may be an index, RIP-relative,
// absolute and index-only addressing.
@(test)
test_addressing :: proc(t: ^testing.T) {
	emitter: Emitter
	emitter_init(&emitter)
	defer emitter_destroy(&emitter)

	loads := []struct {
		src:  Mem,
		want: []byte,
	}{
		{mem_base(RSP, 0), []byte{0x48, 0x8b, 0x04, 0x24}},
		{mem_base(R12, 0), []byte{0x49, 0x8b, 0x04, 0x24}},
		{mem_base(RBP, 0), []byte{0x48, 0x8b, 0x45, 0x00}},
		{mem_base(R13, 0), []byte{0x49, 0x8b, 0x45, 0x00}},
		{mem_base(RBP, 8), []byte{0x48, 0x8b, 0x45, 0x08}},
		{mem_base(RBP, 0x1234), []byte{0x48, 0x8b, 0x85, 0x34, 0x12, 0x00, 0x00}},
		{mem_base_index(RSP, RAX, 4, 0), []byte{0x48, 0x8b, 0x04, 0x84}},
		{mem_base_index(RBX, R12, 2, 0), []byte{0x4a, 0x8b, 0x04, 0x63}},
		{mem_base(RBP, -8), []byte{0x48, 0x8b, 0x45, 0xf8}},
		{mem_base(RAX, -0x1234), []byte{0x48, 0x8b, 0x80, 0xcc, 0xed, 0xff, 0xff}},
		{mem_rip(0x1234), []byte{0x48, 0x8b, 0x05, 0x34, 0x12, 0x00, 0x00}},
		{mem_abs(0x12345678), []byte{0x48, 0x8b, 0x04, 0x25, 0x78, 0x56, 0x34, 0x12}},
		{mem_index(RAX, 8, 0x10), []byte{0x48, 0x8b, 0x04, 0xc5, 0x10, 0x00, 0x00, 0x00}},
	}
	for c in loads {
		emitter_reset(&emitter)
		mov_reg_mem(&emitter, RAX, c.src)
		expect_bytes(t, &emitter, c.want)
	}

	emitter_reset(&emitter)
	mov_reg_mem(&emitter, R8, mem_base(R15, 0x10))
	expect_bytes(t, &emitter, {0x4d, 0x8b, 0x47, 0x10})

	emitter_reset(&emitter)
	mov_mem_reg(&emitter, mem_base(RSP, 8), SIL)
	expect_bytes(t, &emitter, {0x40, 0x88, 0x74, 0x24, 0x08})

	emitter_reset(&emitter)
	lea_reg_mem(&emitter, R8, mem_base_index(RBX, R12, 2, 0x10))
	expect_bytes(t, &emitter, {0x4e, 0x8d, 0x44, 0x63, 0x10})
}

// SPL/BPL/SIL/DIL share their low three bits with the legacy high-byte
// registers and so must force a REX prefix.
@(test)
test_byte_register_rex :: proc(t: ^testing.T) {
	emitter: Emitter
	emitter_init(&emitter)
	defer emitter_destroy(&emitter)

	cases := []struct {
		dst, src: Reg,
		want:     []byte,
	}{
		{AL, BL, []byte{0x88, 0xd8}},
		{SPL, BPL, []byte{0x40, 0x88, 0xec}},
		{SIL, DIL, []byte{0x40, 0x88, 0xfe}},
		{R8B, R15B, []byte{0x45, 0x88, 0xf8}},
	}
	for c in cases {
		emitter_reset(&emitter)
		mov_reg_reg(&emitter, c.dst, c.src)
		expect_bytes(t, &emitter, c.want)
	}

	emitter_reset(&emitter)
	setcc_reg(&emitter, .Greater, SIL)
	expect_bytes(t, &emitter, {0x40, 0x0f, 0x9f, 0xc6})

	emitter_reset(&emitter)
	test_reg_imm(&emitter, BL, 0x7f)
	expect_bytes(t, &emitter, {0xf6, 0xc3, 0x7f})
}

@(test)
test_labels :: proc(t: ^testing.T) {
	emitter: Emitter
	emitter_init(&emitter)
	defer emitter_destroy(&emitter)

	// jmp L0; nop; L0: ret; L1: je L1; call L0
	l0 := label_new(&emitter)
	l1 := label_new(&emitter)
	jmp_label(&emitter, l0)
	nop(&emitter)
	label_bind(&emitter, l0)
	ret(&emitter)
	label_bind(&emitter, l1)
	jcc_label(&emitter, .Equal, l1)
	call_label(&emitter, l0)
	label_resolve(&emitter)

	expect_bytes(
		t,
		&emitter,
		{
			0xe9, 0x01, 0x00, 0x00, 0x00,
			0x90,
			0xc3,
			0x0f, 0x84, 0xfa, 0xff, 0xff, 0xff,
			0xe8, 0xf4, 0xff, 0xff, 0xff,
		},
	)

	offset, ok := label_offset(&emitter, l0)
	testing.expect(t, ok && offset == 6, "label_offset(L0)")
	_, ok = label_offset(&emitter, label_new(&emitter))
	testing.expect(t, !ok, "unbound label has no offset")
}

@(test)
test_gpr_instructions :: proc(t: ^testing.T) {
	emitter: Emitter
	emitter_init(&emitter)
	defer emitter_destroy(&emitter)

	emitter_reset(&emitter)
	mov_reg_reg(&emitter, RAX, RBX)
	expect_bytes(t, &emitter, {0x48, 0x89, 0xd8})

	emitter_reset(&emitter)
	mov_reg_imm(&emitter, RCX, 0x1234)
	expect_bytes(t, &emitter, {0x48, 0xc7, 0xc1, 0x34, 0x12, 0x00, 0x00})

	emitter_reset(&emitter)
	mov_reg_imm(&emitter, RAX, 0x1122334455667788)
	expect_bytes(t, &emitter, {0x48, 0xb8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11})

	emitter_reset(&emitter)
	movzx_reg_reg(&emitter, EAX, BL)
	expect_bytes(t, &emitter, {0x0f, 0xb6, 0xc3})

	emitter_reset(&emitter)
	movsx_reg_reg(&emitter, RAX, BX)
	expect_bytes(t, &emitter, {0x48, 0x0f, 0xbf, 0xc3})

	emitter_reset(&emitter)
	movsxd_reg_reg(&emitter, RAX, EBX)
	expect_bytes(t, &emitter, {0x48, 0x63, 0xc3})

	emitter_reset(&emitter)
	add_reg_reg(&emitter, RAX, RBX)
	expect_bytes(t, &emitter, {0x48, 0x01, 0xd8})

	emitter_reset(&emitter)
	add_reg_imm(&emitter, RBX, 0x7f)
	expect_bytes(t, &emitter, {0x48, 0x83, 0xc3, 0x7f})

	emitter_reset(&emitter)
	add_reg_imm(&emitter, EBX, 0x1234)
	expect_bytes(t, &emitter, {0x81, 0xc3, 0x34, 0x12, 0x00, 0x00})

	emitter_reset(&emitter)
	add_mem_reg(&emitter, mem_base(RBP, -8), RBX)
	expect_bytes(t, &emitter, {0x48, 0x01, 0x5d, 0xf8})

	emitter_reset(&emitter)
	test_reg_reg(&emitter, RCX, RDX)
	expect_bytes(t, &emitter, {0x48, 0x85, 0xd1})

	emitter_reset(&emitter)
	imul_reg_reg(&emitter, RCX, RDX)
	expect_bytes(t, &emitter, {0x48, 0x0f, 0xaf, 0xca})

	emitter_reset(&emitter)
	imul_reg_reg_imm(&emitter, RCX, RDX, 0x10)
	expect_bytes(t, &emitter, {0x48, 0x6b, 0xca, 0x10})

	emitter_reset(&emitter)
	imul_reg_reg_imm(&emitter, RCX, RDX, 0x1234)
	expect_bytes(t, &emitter, {0x48, 0x69, 0xca, 0x34, 0x12, 0x00, 0x00})

	emitter_reset(&emitter)
	idiv_reg(&emitter, RCX)
	expect_bytes(t, &emitter, {0x48, 0xf7, 0xf9})

	emitter_reset(&emitter)
	neg_reg(&emitter, RCX)
	expect_bytes(t, &emitter, {0x48, 0xf7, 0xd9})

	emitter_reset(&emitter)
	not_reg(&emitter, RCX)
	expect_bytes(t, &emitter, {0x48, 0xf7, 0xd1})

	emitter_reset(&emitter)
	cqo(&emitter)
	expect_bytes(t, &emitter, {0x48, 0x99})

	emitter_reset(&emitter)
	cdq(&emitter)
	expect_bytes(t, &emitter, {0x99})

	emitter_reset(&emitter)
	shl_reg_imm(&emitter, RCX, 5)
	expect_bytes(t, &emitter, {0x48, 0xc1, 0xe1, 0x05})

	emitter_reset(&emitter)
	sar_reg_cl(&emitter, R8)
	expect_bytes(t, &emitter, {0x49, 0xd3, 0xf8})

	emitter_reset(&emitter)
	shl_mem_imm(&emitter, mem_base(RSP, 8), 5, .Byte)
	expect_bytes(t, &emitter, {0xc0, 0x64, 0x24, 0x08, 0x05})

	emitter_reset(&emitter)
	shr_mem_cl(&emitter, mem_base(RSP, 8), .Qword)
	expect_bytes(t, &emitter, {0x48, 0xd3, 0x6c, 0x24, 0x08})

	emitter_reset(&emitter)
	setcc_reg(&emitter, .Equal, AL)
	expect_bytes(t, &emitter, {0x0f, 0x94, 0xc0})

	emitter_reset(&emitter)
	cmovcc_reg_reg(&emitter, .Equal, RAX, RBX)
	expect_bytes(t, &emitter, {0x48, 0x0f, 0x44, 0xc3})

	emitter_reset(&emitter)
	cmovcc_reg_mem(&emitter, .Greater, RCX, mem_base(RSP, 8))
	expect_bytes(t, &emitter, {0x48, 0x0f, 0x4f, 0x4c, 0x24, 0x08})

	emitter_reset(&emitter)
	push_reg(&emitter, RCX)
	expect_bytes(t, &emitter, {0x51})

	emitter_reset(&emitter)
	pop_reg(&emitter, R15)
	expect_bytes(t, &emitter, {0x41, 0x5f})

	emitter_reset(&emitter)
	push_imm(&emitter, 0x12345678)
	expect_bytes(t, &emitter, {0x68, 0x78, 0x56, 0x34, 0x12})

	emitter_reset(&emitter)
	call_reg(&emitter, RCX)
	expect_bytes(t, &emitter, {0xff, 0xd1})

	emitter_reset(&emitter)
	jmp_reg(&emitter, R8)
	expect_bytes(t, &emitter, {0x41, 0xff, 0xe0})

	emitter_reset(&emitter)
	call_mem(&emitter, mem_base(RSP, 8))
	expect_bytes(t, &emitter, {0xff, 0x54, 0x24, 0x08})

	emitter_reset(&emitter)
	ret(&emitter)
	expect_bytes(t, &emitter, {0xc3})

	emitter_reset(&emitter)
	ret_imm(&emitter, 0x10)
	expect_bytes(t, &emitter, {0xc2, 0x10, 0x00})

	emitter_reset(&emitter)
	syscall(&emitter)
	expect_bytes(t, &emitter, {0x0f, 0x05})

	emitter_reset(&emitter)
	ud2(&emitter)
	expect_bytes(t, &emitter, {0x0f, 0x0b})

	emitter_reset(&emitter)
	int3(&emitter)
	expect_bytes(t, &emitter, {0xcc})

	emitter_reset(&emitter)
	nop(&emitter)
	expect_bytes(t, &emitter, {0x90})
}

@(test)
test_sse_instructions :: proc(t: ^testing.T) {
	emitter: Emitter
	emitter_init(&emitter)
	defer emitter_destroy(&emitter)

	emitter_reset(&emitter)
	movss_reg_reg(&emitter, XMM0, XMM1)
	expect_bytes(t, &emitter, {0xf3, 0x0f, 0x10, 0xc1})

	emitter_reset(&emitter)
	movss_reg_mem(&emitter, XMM0, mem_base(RSP, 8))
	expect_bytes(t, &emitter, {0xf3, 0x0f, 0x10, 0x44, 0x24, 0x08})

	emitter_reset(&emitter)
	movss_mem_reg(&emitter, mem_base(RSP, 8), XMM0)
	expect_bytes(t, &emitter, {0xf3, 0x0f, 0x11, 0x44, 0x24, 0x08})

	emitter_reset(&emitter)
	movsd_reg_reg(&emitter, XMM8, XMM15)
	expect_bytes(t, &emitter, {0xf2, 0x45, 0x0f, 0x10, 0xc7})

	emitter_reset(&emitter)
	addss_reg_reg(&emitter, XMM0, XMM1)
	expect_bytes(t, &emitter, {0xf3, 0x0f, 0x58, 0xc1})

	emitter_reset(&emitter)
	mulsd_reg_reg(&emitter, XMM0, XMM1)
	expect_bytes(t, &emitter, {0xf2, 0x0f, 0x59, 0xc1})

	emitter_reset(&emitter)
	divss_reg_reg(&emitter, XMM0, XMM1)
	expect_bytes(t, &emitter, {0xf3, 0x0f, 0x5e, 0xc1})

	emitter_reset(&emitter)
	ucomiss_reg_reg(&emitter, XMM0, XMM1)
	expect_bytes(t, &emitter, {0x0f, 0x2e, 0xc1})

	emitter_reset(&emitter)
	ucomisd_reg_reg(&emitter, XMM0, XMM1)
	expect_bytes(t, &emitter, {0x66, 0x0f, 0x2e, 0xc1})

	emitter_reset(&emitter)
	cvtsi2ss_reg_reg(&emitter, XMM0, RCX)
	expect_bytes(t, &emitter, {0xf3, 0x48, 0x0f, 0x2a, 0xc1})

	emitter_reset(&emitter)
	cvttsd2si_reg_reg(&emitter, RCX, XMM0)
	expect_bytes(t, &emitter, {0xf2, 0x48, 0x0f, 0x2c, 0xc8})

	emitter_reset(&emitter)
	movq_reg_reg(&emitter, XMM0, RCX)
	expect_bytes(t, &emitter, {0x66, 0x48, 0x0f, 0x6e, 0xc1})

	emitter_reset(&emitter)
	movq_reg_reg(&emitter, RCX, XMM0)
	expect_bytes(t, &emitter, {0x66, 0x48, 0x0f, 0x7e, 0xc1})

	emitter_reset(&emitter)
	movd_reg_reg(&emitter, XMM0, ECX)
	expect_bytes(t, &emitter, {0x66, 0x0f, 0x6e, 0xc1})

	emitter_reset(&emitter)
	movd_reg_reg(&emitter, ECX, XMM0)
	expect_bytes(t, &emitter, {0x66, 0x0f, 0x7e, 0xc1})
}

@(test)
test_emitter_allocator :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	emitter: Emitter
	emitter_init(&emitter, mem.tracking_allocator(&track))
	for _ in 0 ..< 64 {
		mov_reg_reg(&emitter, RAX, RBX)
	}
	testing.expect(t, len(emitter.code) == 64 * 3, "code length")
	emitter_destroy(&emitter)

	testing.expectf(t, len(track.allocation_map) == 0, "%v allocations leaked", len(track.allocation_map))
}

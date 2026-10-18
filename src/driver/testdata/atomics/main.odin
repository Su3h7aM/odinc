package main

import "base:intrinsics"

main :: proc "contextless" () {
	code := 0
	value := u64(5)
	if intrinsics.atomic_add(&value, 3) == 5 && value == 8 { code += 1 }
	if intrinsics.atomic_exchange(&value, 12) == 8 && value == 12 { code += 2 }
	old, success := intrinsics.atomic_compare_exchange_strong(&value, 12, 17)
	if old == 12 && success && value == 17 { code += 4 }
	failed_old, failed_success := intrinsics.atomic_compare_exchange_strong(&value, 12, 99)
	if failed_old == 17 && !failed_success && value == 17 { code += 8 }
	intrinsics.atomic_store(&value, 23)
	intrinsics.atomic_thread_fence(.Seq_Cst)
	if intrinsics.atomic_load(&value) == 23 { code += 16 }
	intrinsics.atomic_store_explicit(&value, 0xf3, .Release)
	first := intrinsics.atomic_and(&value, 0x3f)
	second := intrinsics.atomic_or(&value, 0x80)
	third := intrinsics.atomic_xor(&value, 0x0f)
	fourth := intrinsics.atomic_nand(&value, 0xff)
	if first == 0xf3 && second == 0x33 && third == 0xb3 && fourth == 0xbc && value == ~u64(0xbc) { code += 32 }
	byte := u8(255)
	word := u16(65535)
	double_word := u32(0xffff_ffff)
	byte_old := intrinsics.atomic_add(&byte, 2)
	word_old := intrinsics.atomic_sub(&word, 2)
	double_old := intrinsics.atomic_exchange(&double_word, 7)
	intrinsics.atomic_thread_fence(.Acquire)
	if byte_old == 255 && byte == 1 && word_old == 65535 && word == 65533 && double_old == 0xffff_ffff && double_word == 7 { code += 64 }
	intrinsics.syscall(60, uintptr(code))
}

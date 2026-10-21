package main

import "base:intrinsics"

main :: proc() {
	code := 0
	flag: bool = false
	intrinsics.atomic_store(&flag, true)
	if intrinsics.atomic_load(&flag) { code += 1 }
	old, ok := intrinsics.atomic_compare_exchange_strong(&flag, true, false)
	if old && ok && !flag { code += 2 }
	failed_old, failed_ok := intrinsics.atomic_compare_exchange_strong(&flag, true, true)
	if !failed_old && !failed_ok && !flag { code += 4 }
	big: b64 = false
	intrinsics.atomic_store_explicit(&big, true, .Release)
	if intrinsics.atomic_load_explicit(&big, .Acquire) { code += 8 }
	wide_old, wide_ok := intrinsics.atomic_compare_exchange_strong(&big, true, false)
	if wide_old == true && wide_ok && big == false { code += 16 }
	weak_old, weak_ok := intrinsics.atomic_compare_exchange_weak(&big, true, false)
	if weak_old == false && !weak_ok && big == false { code += 32 }
	explicit_old, explicit_ok := intrinsics.atomic_compare_exchange_strong_explicit(&big, false, true, .Seq_Cst, .Seq_Cst)
	if explicit_old == false && explicit_ok && big == true { code += 64 }
	intrinsics.syscall(60, uintptr(code))
}

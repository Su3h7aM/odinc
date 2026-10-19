package check

import "core:testing"

@(test)
atomic_compare_exchange_exposes_optional_success_result :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Atomic_Memory_Order :: enum { Relaxed, Acquire }
single :: proc(p: ^i32) -> bool { return 1 == atomic_compare_exchange_strong_explicit(p, 1, 2, .Acquire, .Acquire) }
weak :: proc(p: ^i32) -> i32 { return atomic_compare_exchange_weak(p, 1, 2) }
pair :: proc(p: ^i32) -> bool { old, ok := atomic_compare_exchange_strong(p, 1, 2); return old == 1 && ok }
`,
	)
	names := []string{"atomic_compare_exchange_strong_explicit", "atomic_compare_exchange_strong", "atomic_compare_exchange_weak"}
	for name in ([?]string{"single", "weak", "pair"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name, intrinsic_names = names, package_kind = .Intrinsics)
		if ok { testing.expect(t, procedure.body_state == .Complete) }
	}
}

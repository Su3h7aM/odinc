package check

import "core:testing"

@(test)
intrinsic_likely_and_alloca_check_operand_and_result_shapes :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
branch :: proc "contextless" (ok: bool) -> bool { return likely(ok) }
memory :: proc "contextless" () -> [^]u8 { return alloca(8, 1) }
bad_branch :: proc "contextless" () -> bool { return likely(1) }
`,
	)
	names := []string{"likely", "alloca"}
	for name in ([?]string{"branch", "memory"}) {
		procedure, ok := check_procedure_source(t, source, procedure_name = name, intrinsic_names = names)
		if ok { testing.expect(t, procedure.body_state == .Complete) }
	}
	rejected, rejected_ok := check_procedure_source(t, source, procedure_name = "bad_branch", intrinsic_names = names)
	if rejected_ok { testing.expect(t, rejected.body_state == .Invalid) }
}

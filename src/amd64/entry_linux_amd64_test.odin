package amd64

import x86 "core:rexcode/isa/x86"
import "core:testing"
import "oc:types"

@(test)
microarch_guard_matches_target_level :: proc(t: ^testing.T) {
	levels := [?]types.X86_Level{.V1, .V2, .V3, .V4}
	cpu_counts := [?]int{0, 2, 5, 6}
	xcr_counts := [?]int{0, 0, 1, 2}
	for level, index in levels {
		instructions := make([dynamic]x86.Instruction, context.allocator)
		defer delete(instructions)
		branches := make([dynamic]Pending_Branch, context.allocator)
		defer delete(branches)
		targets := make([dynamic]int, context.allocator)
		defer delete(targets)
		guard_err := emit_microarch_guard(&instructions, &branches, &targets, level)
		testing.expect_value(t, guard_err, nil)
		if guard_err != nil { return }
		if level == .V1 {
			testing.expect_value(t, len(instructions), 0)
		}
		cpuid, xgetbv := 0, 0
		for instruction in instructions {
			if instruction.mnemonic == .CPUID { cpuid += 1 }
			if instruction.mnemonic == .XGETBV { xgetbv += 1 }
		}
		testing.expect_value(t, cpuid, cpu_counts[index])
		testing.expect_value(t, xgetbv, xcr_counts[index])
	}
}

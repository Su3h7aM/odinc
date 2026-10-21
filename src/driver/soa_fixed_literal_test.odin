package driver

import "core:testing"

// Fixed `#soa` literals transpose element rows into the spread columns, both
// for package-level globals (constant) and for locals. Byte-identical to the
// official compiler's output for the same fixture.
soa_fixed_literal_golden :: `V{a = 1, b = 1, c = 1} V{a = 2, b = 2, c = 1} V{a = 3, b = 3, c = 1}
V{a = 1, b = 1, c = 1} V{a = 2, b = 2, c = 1} V{a = 3, b = 3, c = 1}
V{a = 7, b = 7, c = 7} V{a = 7, b = 7, c = 7} V{a = 0, b = 0, c = 0} V{a = 9, b = 9, c = 9}
`

@(test)
soa_fixed_literal_values_match_official :: proc(t: ^testing.T) {
	state, output, ok := soa_access_build_and_run(t, "soa_fixed_literal", true)
	if !ok { return }
	testing.expectf(t, state.exit_code == 0, "soa_fixed_literal exited %d, expected 0", state.exit_code)
	testing.expectf(t, string(output) == soa_fixed_literal_golden, "soa_fixed_literal output must match the official compiler:\n%s", string(output))
}

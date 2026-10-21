package driver

import "core:testing"

// Byte-identical to the official compiler's output for the same fixture,
// verified by running both during development.
soa_zip_golden :: `0 1 2 true
1 3 4 false
2 9 16 true
[1, 3, 9] [2, 4, 16] [true, false, true]
99 2 true
3
1
99 2
9 16
[99, 3, 9] [2, 4, 16]
3 4
`

@(test)
soa_zip_values_match_official :: proc(t: ^testing.T) {
	state, output, ok := soa_access_build_and_run(t, "soa_zip", true)
	if !ok { return }
	testing.expectf(t, state.exit_code == 0, "soa_zip exited %d, expected 0", state.exit_code)
	testing.expectf(t, string(output) == soa_zip_golden, "soa_zip output must match the official compiler:\n%s", string(output))
}

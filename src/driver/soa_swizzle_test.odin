package driver

import "core:testing"

// Direct swizzles over an array-element #soa: reads, scatter writes,
// read-modify-write and range over a swizzle. Byte-identical to the official
// compiler's output for the same fixture, verified by running both.
soa_swizzle_golden :: `1 1
[1, 2] [1, 2]
[1, 2, 3] [1, 2, 3]
[1, 2, 3, 4] [1, 2, 3, 4]
[2, 1] [2, 1]
[1, 1] [1, 1]
[4, 3, 2, 1] [4, 3, 2, 1]
[1, 2] [1, 2]
10 11 3
20 21 90 93
[1, 2] [1, 2]
[3, 1] [3, 1]
40 41 1
[3, 4] [3, 4]
50 51
30 30
35
7
[10, 9]
`

@(test)
soa_swizzle_values_match_official :: proc(t: ^testing.T) {
	state, output, ok := soa_access_build_and_run(t, "soa_swizzle", true)
	if !ok { return }
	testing.expectf(t, state.exit_code == 0, "soa_swizzle exited %d, expected 0", state.exit_code)
	testing.expectf(t, string(output) == soa_swizzle_golden, "soa_swizzle output must match the official compiler:\n%s", string(output))
}

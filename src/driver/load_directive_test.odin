package driver

import "core:testing"

@(test)
load_directive_embeds_relative_file_as_string_and_typed_slices :: proc(t: ^testing.T) {
	expect_exit(t, "load_directive", 42)
	state, _, ok := soa_access_build_and_run(t, "load_directive", false)
	if !ok { return }
	testing.expect_value(t, state.exit_code, 42)
}

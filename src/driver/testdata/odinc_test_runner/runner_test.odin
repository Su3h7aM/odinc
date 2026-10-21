package runner_fixture

import "core:testing"

main :: proc() { panic("main must not run under test") }

@(test)
passing :: proc(t: ^testing.T) { testing.expect(t, true) }

@(test)
failing :: proc(t: ^testing.T) { testing.expect(t, false) }

@(test)
value :: proc(t: ^testing.T) { testing.expect_value(t, 2, 3) }

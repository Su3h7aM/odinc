// The statics of a proc literal that several modules emit are one variable
package test_issue_statics_across_modules

import "a"
import "b"
import "core:testing"

@(test)
test_statics_across_modules :: proc(t: ^testing.T) {
	h := a.H
	testing.expect_value(t, h[0](), [3]int{1, 1, 40})
	testing.expect_value(t, b.call(), [3]int{2, 2, 40})
}

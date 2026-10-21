package check

import "core:testing"

// Dynamic array and map literals allocate, so they need `#+feature dynamic-literals`
// in the file. Empty literals need no allocation and check without the feature.
@(test)
dynamic_literals_require_the_file_feature :: proc(t: ^testing.T) {
	array_source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	values := [dynamic]int{1, 4, 9}
	_ = values
}
`)
	_, array_ok := check_procedure_source(t, array_source, .Invalid_Operand, "Dynamic_Literals_Disallowed", procedure_name = "main")
	if !array_ok { return }
	map_source := transmute([]byte)string(`package sample
main :: proc "contextless" () {
	table := map[string]int{"a" = 1}
	_ = table
}
`)
	_, map_ok := check_procedure_source(t, map_source, .Invalid_Operand, "Dynamic_Literals_Disallowed", procedure_name = "main")
	if !map_ok { return }
	positional_source := transmute([]byte)string(
		`#+feature dynamic-literals
package sample
main :: proc "contextless" () {
	table := map[string]int{1}
	_ = table
}
`,
	)
	_, positional_ok := check_procedure_source(t, positional_source, .Invalid_Operand, "Map_Literal_Field", procedure_name = "main")
	if !positional_ok { return }
}

@(test)
dynamic_literals_check_with_the_file_feature :: proc(t: ^testing.T) {
	array_source := transmute([]byte)string(
		`#+feature dynamic-literals
package sample
main :: proc "contextless" () {
	values := [dynamic]int{1, 4, 9}
	keyed := [dynamic]int{0 = 1, 2 = 3}
	empty := [dynamic]int{}
	_ = values
	_ = keyed
	_ = empty
}
`,
	)
	array_procedure, array_ok := check_procedure_source(t, array_source, procedure_name = "main")
	if array_ok { testing.expect(t, array_procedure.body_state == .Complete) }
	map_source := transmute([]byte)string(
		`#+feature dynamic-literals using-stmt
package sample
main :: proc "contextless" () {
	table := map[string]int{"a" = 1, "b" = 2}
	empty := map[string]int{}
	_ = table
	_ = empty
}
`,
	)
	map_procedure, map_ok := check_procedure_source(t, map_source, procedure_name = "main")
	if map_ok { testing.expect(t, map_procedure.body_state == .Complete) }
}

@(test)
empty_dynamic_literals_check_without_the_file_feature :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
main :: proc "contextless" () {
	values := [dynamic]int{}
	table := map[string]int{}
	_ = values
	_ = table
}
`,
	)
	procedure, ok := check_procedure_source(t, source, procedure_name = "main")
	if ok { testing.expect(t, procedure.body_state == .Complete) }
}

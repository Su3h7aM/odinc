package syntax

import "core:testing"

@(test)
feature_tag_names_are_validated_at_parse_time :: proc(t: ^testing.T) {
	cases := [?]struct {
		source: string,
		errors: []Parse_Error_Kind,
	} {
		{`#+feature dynamic-literals
package sample
`, nil},
		{`#+feature global-context
package sample
`, nil},
		{`#+feature using-stmt
package sample
`, nil},
		{`#+feature force-type-assert
package sample
`, nil},
		{`#+feature integer-division-by-zero:trap
package sample
`, nil},
		{`#+feature integer-division-by-zero:zero
package sample
`, nil},
		{`#+feature integer-division-by-zero:self
package sample
`, nil},
		{`#+feature integer-division-by-zero:all-bits
package sample
`, nil},
		{`#+feature
package sample
`, nil},
		{`#+feature   
package sample
`, nil},
		{`#+feature dynamic-literals using-stmt
package sample
`, nil},
		{`#+feature dynamic-literals
#+feature using-stmt
package sample
`, nil},
		{`#+feature !using-stmt
package sample
`, nil},
		{`#+feature !dynamic-literals
package sample
`, nil},
		{`#+feature !global-context
package sample
`, nil},
		{`#+feature !force-type-assert
package sample
`, nil},
		{`#+feature !integer-division-by-zero:self
package sample
`, nil},
		{`#+feature integer-division-by-zero:trap
#+feature integer-division-by-zero:zero
package sample
`, nil},
		{`#+feature nonsense
package sample
`, {.Invalid_Feature_Flag}},
		{`#+feature dynamic_literals
package sample
`, {.Invalid_Feature_Flag}},
		{`#+feature Dynamic-Literals
package sample
`, {.Invalid_Feature_Flag}},
		{`#+feature dynamic-literals extra
package sample
`, {.Invalid_Feature_Flag}},
		{`#+feature integer-division-by-zero
package sample
`, {.Invalid_Feature_Flag}},
		{`#+feature !nonsense
package sample
`, {.Invalid_Feature_Flag}},
		{`#+feature dynamic-literals,using-stmt
package sample
`, {.Invalid_Feature_Flag}},
		{`#+feature !
package sample
`, {.Expected_Feature_Name}},
		{`#+feature dynamic-literals!
package sample
`, {.Expected_Feature_Name}},
		{`#+feature !integer-division-by-zero:trap
package sample
`, {.Notted_Feature_Flag}},
		{`#+feature !integer-division-by-zero:zero
package sample
`, {.Notted_Feature_Flag}},
		{`#+feature !integer-division-by-zero:all-bits
package sample
`, {.Notted_Feature_Flag}},
		{`#+feature integer-division-by-zero:trap integer-division-by-zero:zero
package sample
`, {.Conflicting_Feature_Flags}},
		{`#+featurex foo
package sample
`, {.Expected_Space_After_Feature}},
	}
	for test_case in cases {
		source := transmute([]byte)test_case.source
		ast: Ast
		ast_init(&ast, context.allocator)
		defer ast_destroy(&ast)
		parser: Parser
		parser_init(&parser, &ast, source, context.allocator)
		defer parser_destroy(&parser)
		parse_file(&parser)
		if !testing.expectf(t, len(parser.errors) == len(test_case.errors), "%q: errors %v", test_case.source, parser.errors) {
			continue
		}
		for error, index in parser.errors {
			testing.expectf(t, error.kind == test_case.errors[index], "%q: error %d kind %v", test_case.source, index, error.kind)
			testing.expectf(t, error.offset == 0, "%q: error %d offset %d", test_case.source, index, error.offset)
		}
	}
}

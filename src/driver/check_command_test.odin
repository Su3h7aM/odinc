package driver

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "oc:analysis"
import "oc:check"
import "oc:syntax"

@(test)
imported_bodies_follow_explicit_lazy_policy :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-lazy-bodies-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	import_directory, _ := filepath.join({directory, "imported"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory(import_directory), nil) { return }
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	import_path, _ := filepath.join({import_directory, "body_test.odin"}, context.temp_allocator)
	for row in ([]struct {
			header, body, call: string,
			reports:            bool,
		}{{"", "bad :: proc(value: int) { _ = transmute(int)value }", "", true}, {"#+lazy\n", "bad :: proc(value: int) { _ = transmute(int)value }", "", false}, {"#+lazy\n", "bad :: proc(value: int) { _ = transmute(int)value }", "imported.bad(1)", true}, {"", "outer :: proc() { nested :: proc(value: int) { _ = transmute(int)value } }", "", true}, {"", "bad :: proc(value: $T) { unknown_generic(value) }", "", false}, {"", "when false { bad :: proc(value: int) { _ = transmute(int)value } }", "", false}, {"#+lazy\n", "@(init) bad :: proc \"contextless\" () { unknown_lazy_init() }", "", true}}) {
		main_source := fmt.tprintf("%s%s%s", "package main\nimport \"imported\"\nmain :: proc() { ", row.call, " }\n")
		import_source := fmt.tprintf("%spackage imported\n%s\n", row.header, row.body)
		if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)main_source), nil) { return }
		if !testing.expect_value(t, os.write_entire_file(import_path, transmute([]byte)import_source), nil) { return }
		log := strings.builder_make()
		error := check_file(
			root,
			main_path,
			strings.to_writer(&log),
			context.allocator,
			false,
			nil,
			nil,
			parse_options = {vet = {.Cast}},
			max_error_count = 100000,
		)
		expected := Driver_Error.Check_Failed if row.reports else .None
		text := strings.to_string(log)
		testing.expectf(t, error == expected, "%s: got %v, expected %v: %s", row.body, error, expected, text)
		found := strings.contains(text, "Unneeded transmute") || strings.contains(text, "Undeclared name: unknown_lazy_init")
		testing.expect_value(t, found, row.reports)
		strings.builder_destroy(&log)
	}
}

@(test)
escape_return_certainty_preserves_source_reads_and_object_fields :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-escape-values-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	source := `package main
Holder :: struct { pointer: ^int }
direct :: proc() -> ^int { local := 1; return &local }
copied :: proc() -> ^int { local := 1; pointer := &local; return pointer }
aggregate :: proc() -> Holder { local := 1; return Holder{pointer = &local} }
field :: proc() -> ^int { local := 1; holder := Holder{pointer = &local}; return holder.pointer }
cleared :: proc() -> Holder { local := 1; holder := Holder{pointer = &local}; holder.pointer = nil; return holder }
boxed :: proc() -> any { return 1 }
boxed_copy :: proc() -> any { value: any = 1; return value }
boxed_parameter :: proc(parameter: int) -> any { return parameter }
variadic :: proc(arguments: ..int) -> []int { return arguments }
variadic_any :: proc(arguments: ..any) -> any { return arguments[0] }
empty :: proc() -> []int { return []int{} }
nil_slice :: proc() -> []int { return ([]int)(nil) }
parenthesized_empty :: proc() -> []int { return ([]int{}) }
alias_clear :: proc() -> ^int { local := 1; pointer := &local; alias := &pointer; alias^ = nil; return pointer }
raw :: proc() -> ^int { local := 1; return (^int)(rawptr(&local)) }
integer :: proc() -> ^int { local := 1; return (^int)(uintptr(&local)) }
transmuted :: proc() -> ^int { local := 1; return transmute(^int)&local }
constant_any_call :: proc() -> any { return any(1) }
constant_any_cast :: proc() -> any { return cast(any)1 }
constant_any_auto :: proc() -> any { return auto_cast 1 }
constant_any_parens :: proc() -> any { return (any(1)) }
constant_any_declaration :: proc() -> any { value: any = any(1); return value }
constant_any_assignment :: proc() -> any { value: any; value = any(1); return value }
CONSTANT_SLICE :: []int{1}
constant_any_named :: proc() -> any { return any(CONSTANT_SLICE) }
implicit_any_call :: proc() -> any { return int(1) }
implicit_any_cast :: proc() -> any { return cast(int)1 }
main :: proc() {}
`
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)source), nil) { return }
	session, error := check_program(root, main_path, context.allocator, false)
	defer session_destroy(session)
	if !testing.expect_value(t, error, .Check_Failed) { return }
	errors, warnings: int
	for diagnostic in session.analysis_result.diagnostics {
		if diagnostic.severity == .Error { errors += 1 } else { warnings += 1 }
	}
	testing.expect_value(t, errors, 7)
	testing.expect_value(t, warnings, 5)
	log := strings.builder_make()
	defer strings.builder_destroy(&log)
	write_diagnostics(session, strings.to_writer(&log))
	text := strings.to_string(log)
	for expected in ([]string{"return '&local' from a procedure, as it refers to the stack memory of the local variable 'local'", "return 'pointer' from a procedure, as it may refer to the stack memory of the local variable 'local'", "return '1' from a procedure, as it refers to the stack memory of a temporary value", "return 'parameter' from a procedure, as it refers to the stack memory of a temporary value", "the variadic parameter 'arguments', which only lives for the duration of the call", "Suggestion: If this is intended, make it explicit with a conversion to 'rawptr' or 'uintptr', or a 'transmute'"}) { testing.expect(t, strings.contains(text, expected), text) }
}

@(test)
escape_budget_skips_nil_deref_past_fact_budget_and_keeps_returns :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-escape-budget-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "#+vet nil-deref\npackage main\nret_local :: proc() -> ^int { x := 1; return &x }\n")
	write_escape_budget_body(&builder, "large", 9000)
	write_escape_budget_body(&builder, "small", 100)
	strings.write_string(&builder, "main :: proc() { large(); small(); _ = ret_local() }\n")
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)strings.to_string(builder)), nil) { return }
	session, error := check_program(root, main_path, context.allocator, false)
	defer session_destroy(session)
	if !testing.expect_value(t, error, .Check_Failed) { return }
	nil_derefs, stack_returns := 0, 0
	for diagnostic in session.analysis_result.diagnostics {
		if strings.contains(diagnostic.reason, "Dereferencing 'np'") { nil_derefs += 1 }
		if strings.contains(diagnostic.reason, "stack memory") { stack_returns += 1 }
	}
	testing.expect_value(t, nil_derefs, 1)
	testing.expect_value(t, stack_returns, 1)
}

@(private = "file")
write_escape_budget_body :: proc(builder: ^strings.Builder, name: string, locals: int) {
	strings.write_string(builder, name)
	strings.write_string(builder, " :: proc() {\n")
	for index in 0 ..< locals {
		fmt.sbprintf(builder, "\tx%d := 0\n\tp%d := &x%d\n\t_ = p%d\n", index, index, index, index)
	}
	strings.write_string(builder, "\tnp: ^int\n\t_ = np^\n}\n")
}

@(test)
disabled_escape_analysis_checks_return_storage_without_lowering :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-unsafe-return-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	data_path, _ := filepath.join({directory, "data.txt"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(data_path, []byte{'x'}), nil) { return }
	source := `package main
Holder :: struct { p: ^int }
E :: enum { A, B }
literal :: proc() -> []int { return []int{1} }
local :: proc() -> ^int { x := 1; return &x }
compound :: proc() -> ^Holder { return &Holder{} }
indexed :: proc() -> ^int { x: [2]int; return &x[0] }
enumerated :: proc() -> ^int { x: [E]int; return &x[.A] }
matrix_value :: proc() -> ^f32 { x: matrix[2, 3]f32; return &x[ 0,1 ] }
slice_local :: proc() -> []int { x: [2]int; return x[:] }
slice_compound :: proc() -> []int { x := 1; return []int{x}[:] }
DATA :: []int{1}
constant_slice :: proc() -> []int { return DATA }
nested :: proc() -> Holder { x := 1; return Holder{p = &x} }
identity :: proc() -> []int { x: [2]int; return ([]int)(x[:]) }
empty :: proc() -> []int { return []int{} }
nil_value :: proc() -> []int { return nil }
nil_cast :: proc() -> []int { return ([]int)(nil) }
loaded :: proc() -> []u8 { return #load("data.txt") }
safe_cast :: proc() -> rawptr { x := 1; return rawptr(&x) }
safe_transmute :: proc() -> ^int { x := 1; return transmute(^int)&x }
global: int
global_address :: proc() -> ^int { return &global }
static_address :: proc() -> ^int { @(static) x := 1; return &x }
range_address :: proc() -> ^int { xs: [1]int; for &x in xs { return &x }; return nil }
switch_address :: proc(x: union {int, bool}) -> ^int {
 y := x
 switch &v in y { case int: return &v; case bool: return nil }
 return nil
}
when false { inactive :: proc() -> ^int { x := 1; return &x } }
main :: proc() {}
`
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)source), nil) { return }
	session, error := check_program(root, main_path, context.allocator, false, parse_options = {no_analysis = {.Escape}})
	defer session_destroy(session)
	if !testing.expect_value(t, error, Driver_Error.Check_Failed) { return }
	testing.expect(t, len(session.analysis_result.procedures) > 1 && len(session.analysis_result.events) > 1)
	testing.expect_value(t, len(session.analysis_result.diagnostics), 11)
	log := strings.builder_make()
	write_diagnostics(session, strings.to_writer(&log))
	text := strings.to_string(log)
	for expected in ([]string{"a compound literal of a slice ('[]int{1}')", "the address of a local variable ('&x')", "the address of a compound literal ('&Holder{}')", "the address of an indexed variable ('&x[0]') of type ('[2]int')", "the address of an indexed variable ('&x[.A]') of type ('[E]int')", "the address of an indexed variable ('&x[0, 1]') of type ('matrix[2, 3]f32')", "a slice of a local variable ('x[:]')", "a slice of a compound literal ('[]int{x}[:]')", "a compound literal of a slice ('DATA')", "Note: A constant slice value will use the memory of the current stack frame", "the address of a local variable ('Holder{p = &x}')", "a slice of a local variable ('([]int)(x[:])')"}) { testing.expect(t, strings.contains(text, expected), text) }
	strings.builder_destroy(&log)
}

@(test)
analysis_policy_and_diagnostics_use_the_common_check_path :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-analysis-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	for row in ([]struct {
			tags:  string,
			flags: syntax.Analysis_Flags,
		}{{"", {}}, {"#+analysis escape\n", {.Escape}}, {"#+analysis\n#+analysis !escape\n", {.Atomic}}, {"#+analysis atomic\n#+analysis !atomic escape\n", {.Escape}}, {"#+analysis\n", syntax.ANALYSIS_ALL}}) {
		source := strings.concatenate({row.tags, "package main\nmain :: proc() {}\n"}, context.temp_allocator) or_else ""
		if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)source), nil) { return }
		session, error := check_program(root, main_path, context.allocator, false, parse_options = {no_analysis = syntax.ANALYSIS_ALL})
		defer session_destroy(session)
		if !testing.expect_value(t, error, .None) { continue }
		testing.expect_value(t, session.analysis_result.enabled, row.flags)
		testing.expect_value(t, len(session.analysis_result.diagnostics), 0)
		main_file: check.File_Id
		for file, index in session.program.files {
			if file.path == main_path {
				main_file = check.File_Id(index)
				testing.expect_value(t, file.ast.analysis, row.flags)
			}
		}
		if !testing.expect(t, main_file != 0) { continue }
		diagnostics := [?]analysis.Diagnostic {
			{severity = .Warning, source = {file = main_file}, reason = "analysis warning"},
			{severity = .Error, source = {file = main_file}, reason = "analysis error"},
		}
		session.analysis_result.diagnostics = diagnostics[:]
		session.check_options.ignore_warnings = true
		log := strings.builder_make()
		write_diagnostics(session, strings.to_writer(&log))
		testing.expect(t, session_has_errors(session))
		testing.expect(t, !strings.contains(strings.to_string(log), "analysis warning"))
		testing.expect(t, strings.contains(strings.to_string(log), "Error: analysis error"))
		strings.builder_destroy(&log)
		session.analysis_result.diagnostics = nil
	}
	for row in ([]struct {
			tag, text: string,
		}{{"#+analysisx", "Expected a space after #+analysis"}, {"#+analysis\tescape", "Expected a space after #+analysis"}, {"#+analysis !", "Expected an analysis name after '!'"}, {"#+analysis unknown", "Invalid analysis name: unknown\n\tExpected one of the following\n\tescape\n\tatomic"}}) {
		source := strings.concatenate({row.tag, "\npackage main\n"}, context.temp_allocator) or_else ""
		ast: syntax.Ast
		syntax.ast_init(&ast)
		defer syntax.ast_destroy(&ast)
		parser: syntax.Parser
		syntax.parser_init(&parser, &ast, transmute([]byte)source)
		defer syntax.parser_destroy(&parser)
		syntax.parse_file(&parser)
		if testing.expect_value(t, len(parser.errors), 1) {
			testing.expect(t, strings.has_prefix(syntax.parse_error_text(parser.errors[0]), row.text), syntax.parse_error_text(parser.errors[0]))
		}
	}
	atomic_flags, atomic_tag_error, _ := syntax.parse_vet_tag(" atomic-access", {})
	testing.expect_value(t, atomic_tag_error, .None)
	testing.expect_value(t, atomic_flags, syntax.Vet_Flags{.Atomic_Access})
	for name in ([]string{"check", "build", "run", "test"}) {
		command, error := parse_command_arguments(name, []string{".", "--no-escape-analysis", "--no-atomic-analysis"})
		defer delete(command.collections)
		defer delete(command.options.defines)
		testing.expect_value(t, error, "")
		testing.expect_value(t, command.options.parse_options.no_analysis, syntax.ANALYSIS_ALL)
		atomic_command, atomic_error := parse_command_arguments(name, []string{".", "--vet-atomic-access"})
		defer delete(atomic_command.collections)
		defer delete(atomic_command.options.defines)
		testing.expect_value(t, atomic_error, "")
		testing.expect_value(t, atomic_command.options.parse_options.vet, syntax.Vet_Flags{.Atomic_Access})
		testing.expect(t, .Atomic_Access not_in syntax.VET_ALL)
		nil_flags, nil_tag_error, _ := syntax.parse_vet_tag(" nil-deref", {})
		testing.expect_value(t, nil_tag_error, .None)
		testing.expect_value(t, nil_flags, syntax.Vet_Flags{.Nil_Deref})
		uninitialized_flags, uninitialized_tag_error, _ := syntax.parse_vet_tag(" uninitialized", {})
		testing.expect_value(t, uninitialized_tag_error, .None)
		testing.expect_value(t, uninitialized_flags, syntax.Vet_Flags{.Uninitialized})
		testing.expect(t, .Nil_Deref not_in syntax.VET_ALL)
		testing.expect(t, .Uninitialized not_in syntax.VET_ALL)
		nil_command, nil_error := parse_command_arguments("check", []string{".", "--vet-nil-deref"})
		defer delete(nil_command.collections)
		defer delete(nil_command.options.defines)
		testing.expect_value(t, nil_error, "")
		testing.expect(t, .Nil_Deref in nil_command.options.parse_options.vet)
		uninitialized_command, uninitialized_error := parse_command_arguments("check", []string{".", "--vet-uninitialized"})
		defer delete(uninitialized_command.collections)
		defer delete(uninitialized_command.options.defines)
		testing.expect_value(t, uninitialized_error, "")
		testing.expect(t, .Uninitialized in uninitialized_command.options.parse_options.vet)
	}
	for row in ([]struct {
			arguments: []string,
			message:   string,
		}{{{".", "--no-escape-analysis", "--vet-nil-deref"}, "--vet-nil-deref and --vet-uninitialized cannot be used with --no-escape-analysis, as they are part of it"}, {{".", "--no-escape-analysis", "--vet-uninitialized"}, "--vet-nil-deref and --vet-uninitialized cannot be used with --no-escape-analysis, as they are part of it"}, {{".", "--no-atomic-analysis", "--vet-atomic-access"}, "--vet-atomic-access cannot be used with --no-atomic-analysis, as it is part of it"}, {{".", "--vet-atomic-access", "--no-atomic-analysis"}, "--vet-atomic-access cannot be used with --no-atomic-analysis, as it is part of it"}}) {
		command, error := parse_command_arguments("check", row.arguments)
		defer delete(command.collections)
		defer delete(command.options.defines)
		testing.expect_value(t, error, row.message)
	}
}

@(test)
check_command_warning_controls_and_anonymous_type_diagnostics :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-warnings-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	source := `package main
S :: struct #field_align(8) { x: int }
main :: proc() {
	x: struct { a: int }
	_ = cast(type_of(x))x
	y: union { int, string }
	_ = cast(type_of(y))y
	e: enum { A, B }
	_ = cast(type_of(e))e
	b: bit_set[0..=3]
	_ = cast(type_of(b))b
	p: proc "contextless" (x: int, args: ..string) -> (a: bool, b: int)
	_ = cast(type_of(p))p
}
`
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)source), nil) { return }
	for row in ([]struct {
			vet:     syntax.Vet_Flags,
			options: check.Check_Options,
			error:   Driver_Error,
			warning: bool,
		}{{{}, {}, .None, true}, {{.Deprecated}, {}, .None, true}, {{}, {warnings_as_errors = true}, .Check_Failed, true}, {{}, {ignore_warnings = true}, .None, false}, {{.Cast}, {ignore_warnings = true}, .Check_Failed, false}}) {
		log := strings.builder_make()
		error := check_file(
			root,
			main_path,
			strings.to_writer(&log),
			context.allocator,
			false,
			nil,
			nil,
			parse_options = {vet = row.vet},
			check_options = row.options,
		)
		testing.expect_value(t, error, row.error)
		text := strings.to_string(log)
		testing.expect_value(t, strings.contains(text, "#field_align has been deprecated in favour of #min_field_align"), row.warning)
		if .Cast in row.vet {
			for spelling in ([]string{"struct {a: int}", "union {int, string}", "enum int {A, B}", "bit_set[0..=3]", "proc \"contextless\" (int, ..string) -> (bool, int)"}) {
				testing.expect(t, strings.contains(text, spelling), text)
			}
		}
		strings.builder_destroy(&log)
	}
	for arguments, index in ([][]string{{".", "--ignore-warnings", "--warnings-as-errors"}, {".", "--warnings-as-errors", "--ignore-warnings"}}) {
		command, error := parse_command_arguments("check", arguments)
		defer delete(command.collections)
		defer delete(command.options.defines)
		expected :=
			"--warnings-as-errors cannot be used with --ignore-warnings" if index == 0 else "--ignore-warnings cannot be used with --warnings-as-errors"
		testing.expect_value(t, error, expected)
	}
}

@(test)
check_command_checks_without_building :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	for row in ([]struct {
			source:         string,
			no_entry_point: bool,
			error:          Driver_Error,
			diagnostic:     string,
		}{{"package main\nmain :: proc() {}\n", false, .None, ""}, {"package library\nvalue :: 1\n", false, .Check_Failed, "Undefined entry point procedure 'main'"}, {"package library\n#assert(ODIN_NO_ENTRY_POINT)\nvalue :: 1\n", true, .None, ""}, {"package main\nmain :: proc() { value: int = \"bad\"; _ = value }\n", false, .Check_Failed, "Conversion"}, {"package main\nmain :: proc() { value := }\n", false, .Parse_Failed, "Syntax Error: Expected_Operand"}, {"package main\nmain :: proc(value: int) {}\n", false, .Check_Failed, "Procedure type of 'main' was expected to be 'proc()'"}, {"package main\nmain :: 42\n", false, .Check_Failed, "'main' is reserved as the entry point procedure"}, {"package main\nmain :: 42\n", true, .Check_Failed, "'main' is reserved as the entry point procedure"}, {"package main\nmain :: proc \"contextless\" () {}\n", true, .None, ""}}) {
		if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)row.source), nil) { return }
		log := strings.builder_make()
		error := check_file(root, main_path, strings.to_writer(&log), context.allocator, row.no_entry_point, nil, nil)
		testing.expect_value(t, error, row.error)
		if row.diagnostic == "" {
			testing.expect_value(t, strings.to_string(log), "")
		} else {
			testing.expect(t, strings.contains(strings.to_string(log), row.diagnostic), strings.to_string(log))
		}
		strings.builder_destroy(&log)
	}
}

@(test)
check_directory_keeps_vet_semicolon_diagnostics :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-vet-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)string("package main\nmain :: proc() { _ = 1; }\n")), nil) { return }
	for enabled in ([2]bool{false, true}) {
		log := strings.builder_make()
		defer strings.builder_destroy(&log)
		error := check_file(
			root,
			directory,
			strings.to_writer(&log),
			context.allocator,
			false,
			nil,
			nil,
			parse_options = {vet = {.Semicolon} if enabled else {}},
		)
		testing.expect_value(t, error, Driver_Error.Parse_Failed if enabled else Driver_Error.None)
		if enabled {
			testing.expect(t, strings.contains(strings.to_string(log), "Syntax Error: Found unneeded semicolon"), strings.to_string(log))
		} else {
			testing.expect_value(t, strings.to_string(log), "")
		}
	}
}

@(test)
check_command_reports_when_shadowing_and_deprecated_imports :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-when-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	for row in ([]struct {
			source: string,
			vet:    syntax.Vet_Flags,
			error:  Driver_Error,
			text:   string,
		}{{"package main\nwhen true {\n\tlen :: 1\n}\nmain :: proc() {}\n", {.When_Shadowing}, .Check_Failed, "Declaration of 'len' within a global 'when' shadows the builtin 'len'"}, {"package main\nwhen true {\n\tlen :: 1\n}\nmain :: proc() {}\n", {}, .None, ""}, {"package main\nimport \"core:runtime\"\nmain :: proc() {}\n", {.Deprecated}, .Check_Failed, "Error: import \"core:runtime\" has been deprecated in favour of \"base:runtime\""}, {"package main\nimport \"core:runtime\"\nmain :: proc() {}\n", {}, .None, "Warning: import \"core:runtime\" has been deprecated in favour of \"base:runtime\""}}) {
		if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)row.source), nil) { return }
		log := strings.builder_make()
		error := check_file(root, main_path, strings.to_writer(&log), context.allocator, false, nil, nil, parse_options = {vet = row.vet})
		testing.expect_value(t, error, row.error)
		testing.expect(t, strings.contains(strings.to_string(log), row.text), strings.to_string(log))
		strings.builder_destroy(&log)
	}
}

@(test)
check_command_reports_unused_procedures_and_ignores_type_switch_variables :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-unused-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	source := "package sample\nhelper :: proc() {}\nused :: proc() {}\nmain :: proc() {\n\tused()\n\tvalue: union {int, bool}\n\tswitch v in value {\n\tcase int:\n\tcase bool:\n\t}\n}\n"
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)source), nil) { return }
	for row in ([]struct {
			vet:      syntax.Vet_Flags,
			packages: []string,
			error:    Driver_Error,
		}{{{.Unused_Procedures, .Unused_Variables}, {"sample"}, .Check_Failed}, {{.Unused_Procedures}, {"other"}, .None}}) {
		log := strings.builder_make()
		error := check_file(
			root,
			main_path,
			strings.to_writer(&log),
			context.allocator,
			false,
			nil,
			nil,
			parse_options = {vet = row.vet, vet_packages = row.packages},
		)
		testing.expect_value(t, error, row.error)
		text := strings.to_string(log)
		testing.expect_value(t, strings.contains(text, "'helper' declared but not used"), row.error == .Check_Failed)
		testing.expect(t, !strings.contains(text, "'used'") && !strings.contains(text, "'main'") && !strings.contains(text, "'v'"), text)
		strings.builder_destroy(&log)
	}
}

@(test)
check_command_handles_local_foreign_blocks_explicit_allocators_and_excluded_packages :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-foreign-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	package_directory, _ := filepath.join({directory, "excluded"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory(package_directory), nil) { return }
	excluded_path, _ := filepath.join({package_directory, "excluded.odin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(excluded_path, transmute([]byte)string("#+build darwin\npackage excluded\n")), nil) { return }
	for row in ([]struct {
			source: string,
			vet:    syntax.Vet_Flags,
			error:  Driver_Error,
			text:   string,
		}{{"package main\nforeign import libc \"system:c\"\nmain :: proc() {\n\tforeign libc {\n\t\tputs :: proc(text: cstring) -> i32 ---\n\t}\n\t_ = puts(\"\")\n}\n", {}, .None, ""}, {"package main\nimport \"excluded\"\nmain :: proc() {}\n", {}, .None, ""}, {"package main\nforeign import libc \"system:c\"\nforeign libc {\n\tputs :: proc(text: cstring) -> i32 ---\n\twhen true {  }\n}\nmain :: proc() { _ = puts(\"\") }\n", {}, .None, ""}, {"#+vet explicit-allocators\npackage main\nmake_value :: proc(allocator := context.allocator) {}\nmain :: proc() {\n\tmake_value()\n\tmake_value(context.allocator)\n}\n", {}, .Check_Failed, "Error: Parameter 'allocator' of type 'Allocator' must be explicitly provided in procedure call"}, {"package main\nmake_value :: proc(allocator := context.allocator) {}\nmain :: proc() { make_value() }\n", {}, .None, ""}}) {
		if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)row.source), nil) { return }
		log := strings.builder_make()
		error := check_file(root, main_path, strings.to_writer(&log), context.allocator, false, nil, nil, parse_options = {vet = row.vet})
		testing.expect_value(t, error, row.error)
		testing.expect(t, strings.contains(strings.to_string(log), row.text), strings.to_string(log))
		strings.builder_destroy(&log)
	}
}

@(test)
check_command_tracks_uninitialized_paths_and_caps_errors :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory, directory_error := os.make_directory_temp("", "driver-check-uninitialized-*", context.temp_allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer os.remove_all(directory)
	main_path, _ := filepath.join({directory, "main.odin"}, context.temp_allocator)
	source := `package sample
Pair :: struct { left, right: int }
produce :: proc() -> (int, int) { return 0, 1 }
inspect :: proc() {
	value: int = ---
	_ = &value
	_ = value
	pointer: ^int
	_ = &pointer
	pointer = nil
	_ = pointer^
	tuple: int = ---
	_, tuple = produce()
	_ = tuple
	array: [2]int = ---
	array[0] = 1
	_ = array[1]
	pair: Pair = ---
	pair.left = 1
	_ = pair.left
	_ = pair.right
	other: int = ---
	_ = other
}
`
	if !testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)source), nil) { return }
	for maximum in 1 ..= 2 {
		log := strings.builder_make()
		error := check_file(
			root,
			main_path,
			strings.to_writer(&log),
			context.allocator,
			true,
			nil,
			nil,
			parse_options = {vet = {.Uninitialized, .Nil_Deref}},
			max_error_count = maximum,
		)
		testing.expect_value(t, error, Driver_Error.Check_Failed)
		text := strings.to_string(log)
		testing.expect_value(t, strings.count(text, "before anything is stored in it"), maximum)
		testing.expect(t, strings.contains(text, "Reading 'pair.right'"), text)
		testing.expect(t, !strings.contains(text, "Reading 'array'") && !strings.contains(text, "Reading 'value'"), text)
		strings.builder_destroy(&log)
	}
}

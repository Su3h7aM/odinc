package check

import "core:strings"
import "core:testing"

@(test)
procedure_bodies_must_terminate_as_official_check_is_terminating :: proc(t: ^testing.T) {
	// Official: Missing return statement at the end of the procedure 'f'.
	rejected := [?]string {
		"f :: proc(x: int) -> int { if x > 0 { return 1 } }",
		"f :: proc(x: int) -> int { switch x { case 1: return 1 } }",
		"f :: proc(x: int) -> int { switch x { case 1: return 1; case: x += 1 } }",
		"f :: proc(x: int) -> int { for { if x > 0 { break } } }",
		"f :: proc(x: int) -> int { for x > 0 { return 1 } }",
		"f :: proc(x: int) -> int { for i in 0 ..< x { return 1 } }",
		"f :: proc(x: int) -> int { loop: for { for { break loop } } }",
	}
	for source in rejected {
		_, ok := check_procedure_source(t, transmute([]byte)string(sample(source)), .Missing_Return, procedure_name = "f")
		testing.expectf(t, ok, "must reject: %s", source)
	}
	accepted := [?]string {
		"f :: proc(x: int) -> int { if x > 0 { return 1 } else { return 2 } }",
		"f :: proc(x: int) -> int { switch x { case 1: return 1; case: return 2 } }",
		"f :: proc(x: int) -> int { for { if x > 0 { return 1 } } }",
		"f :: proc(x: int) -> int { for { for { break } } }",
		"f :: proc(x: int) -> int { loop: for { for { continue loop } } }",
		"f :: proc(x: int) -> int { panic_now() }\npanic_now :: proc() -> ! { for {} }",
		"f :: proc(x: int) -> int { return 1; }",
	}
	for source in accepted {
		procedure, ok := check_procedure_source(t, transmute([]byte)string(sample(source)), procedure_name = "f")
		if ok { testing.expectf(t, procedure.body_state == .Complete, "must accept: %s", source) }
	}
}

@(test)
diverging_procedure_must_end_in_a_diverging_statement :: proc(t: ^testing.T) {
	// Official: Missing diverging call at the end of the procedure 'f'.
	_, ok := check_procedure_source(t, transmute([]byte)string(sample("f :: proc() -> ! { }")), .Missing_Diverging_Call, procedure_name = "f")
	testing.expect(t, ok)
}

@(test)
context_requires_an_odin_convention_or_an_assignment :: proc(t: ^testing.T) {
	// Official: 'context' has not been defined within this scope.
	rejected := [?]string {
		"f :: proc \"contextless\" () { _ = context }",
		"f :: proc \"c\" () { _ = context.allocator }",
		"f :: proc \"contextless\" () { context.allocator = context.allocator }",
	}
	for source in rejected {
		_, ok := check_procedure_source(t, transmute([]byte)string(sample(source)), .Undefined_Context, procedure_name = "f")
		testing.expectf(t, ok, "must reject: %s", source)
	}
}

@(test)
main_of_the_main_package_cannot_have_a_custom_calling_convention :: proc(t: ^testing.T) {
	// Official: Procedure 'main' cannot have a custom calling convention.
	_, ok := check_procedure_source(
		t,
		transmute([]byte)string(sample("main :: proc \"contextless\" () { }")),
		.Main_Calling_Convention,
		procedure_name = "main",
		package_name = "main",
	)
	testing.expect(t, ok)
}

@(private = "file")
sample :: proc(source: string) -> string {
	return strings.concatenate({"package sample\n", source, "\n"}, context.temp_allocator)
}

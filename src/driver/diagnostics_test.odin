package driver

import "core:strings"
import "core:testing"
import "oc:check"
import "oc:lower"

@(test)
source_less_lower_error_prints_without_location :: proc(t: ^testing.T) {
	session: Session
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	errors := []lower.Lower_Error{{code = .Unsupported, feature = .Startup, source = check.Source_Span{}}}
	write_lower_errors(&session, strings.to_writer(&builder), errors)
	testing.expect_value(t, strings.to_string(builder), "lower Unsupported Startup\n")
}

@(test)
verification_error_prints_verify_code :: proc(t: ^testing.T) {
	session: Session
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	errors := []lower.Lower_Error{{code = .Verification, feature = .Operator, source = check.Source_Span{}, verify_code = .Bad_Type}}
	write_lower_errors(&session, strings.to_writer(&builder), errors)
	testing.expect_value(t, strings.to_string(builder), "lower Verification Operator Bad_Type\n")
}

@(test)
conversion_error_prints_without_verify_code :: proc(t: ^testing.T) {
	session: Session
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	errors := []lower.Lower_Error{{code = .Unsupported, feature = .Conversion, source = check.Source_Span{}}}
	write_lower_errors(&session, strings.to_writer(&builder), errors)
	testing.expect_value(t, strings.to_string(builder), "lower Unsupported Conversion\n")
}

@(test)
checker_conversion_error_prints_code_and_reason :: proc(t: ^testing.T) {
	file := check.File {
		display_path = "sample.odin",
	}
	session: Session
	session.files = make([dynamic]^check.File, 0, 2, context.temp_allocator)
	append(&session.files, nil, &file)
	session.checker.diagnostics = make([dynamic]check.Expression_Diagnostic, 0, 2, context.temp_allocator)
	append(
		&session.checker.diagnostics,
		check.Expression_Diagnostic{kind = .Conversion, conversion = .Not_Assignable, source = {file = 1}},
		check.Expression_Diagnostic{kind = .Conversion, conversion = .Unsupported, reason = "details", source = {file = 1}},
	)
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	write_diagnostics(&session, strings.to_writer(&builder))
	testing.expect_value(t, strings.to_string(builder), "sample.odin:1:1: Conversion Not_Assignable\nsample.odin:1:1: Conversion Unsupported details\n")
}

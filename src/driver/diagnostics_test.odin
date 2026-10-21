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

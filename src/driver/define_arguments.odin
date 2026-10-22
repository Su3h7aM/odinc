package driver

import "core:fmt"
import "core:strings"

// Parses one `--define` value `NAME=value` into defines. Returns Invalid_Define when NAME or the value is
// empty or `=` is missing.
parse_define_argument :: proc(defines: ^map[string]string, value: string) -> Driver_Error {
	separator := strings.index_byte(value, '=')
	if separator <= 0 || separator == len(value) - 1 { return .Invalid_Define }
	defines[value[:separator]] = value[separator + 1:]
	return .None
}

// The official driver's message for a define value that parse_define_argument rejects.
define_argument_error_message :: proc(value: string) -> string {
	if value == "" { return "Flag missing for 'define'" }
	return fmt.tprintf("Expected 'name=value', got '%s'", value)
}

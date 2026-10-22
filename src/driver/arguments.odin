package driver

import "core:strings"

// A `--name` or `--name=value` argument. `has_value` tells `--name=` from `--name`.
Long_Flag :: struct {
	name:      string,
	value:     string,
	has_value: bool,
}

// Splits one long argument. ok is false for an argument that is not `--name[=value]`.
split_long_flag :: proc(argument: string) -> (flag: Long_Flag, ok: bool) {
	if len(argument) < 3 || !strings.has_prefix(argument, "--") { return {}, false }
	flag.name = argument[2:]
	if separator := strings.index_byte(flag.name, '='); separator >= 0 {
		flag.value = flag.name[separator + 1:]
		flag.name = flag.name[:separator]
		flag.has_value = true
	}
	return flag, flag.name != ""
}

// Any argument that starts with a dash is a flag, never an input path or a flag value.
argument_is_flag :: proc(argument: string) -> bool {
	return len(argument) > 0 && argument[0] == '-'
}

// Splits the `name=path` value of `--collection` at its first `=`.
collection_from_value :: proc(value: string) -> (collection: Collection, ok: bool) {
	separator := strings.index_byte(value, '=')
	if separator <= 0 || separator == len(value) - 1 { return {}, false }
	return Collection{value[:separator], value[separator + 1:]}, true
}

// Takes the value of a long flag: `--flag=value`, or `--flag value` from the next argument, which the index
// is advanced past. ok is false when the value is missing or empty.
take_flag_value :: proc(args: []string, index: ^int, flag: Long_Flag) -> (value: string, ok: bool) {
	if flag.has_value { return flag.value, flag.value != "" }
	if index^ + 1 >= len(args) || argument_is_flag(args[index^ + 1]) { return "", false }
	index^ += 1
	return args[index^], args[index^] != ""
}

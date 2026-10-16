package main

import "core:fmt"
import "core:strconv"
import "core:strings"

// Module is the part of an LLVM IR text file the comparison needs: the lines of
// function definitions and the bodies of named struct types.
Module :: struct {
	definitions: [dynamic]string,
	named:       map[string]string,
}

parse_module :: proc(source: string) -> (module: Module) {
	text := source
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "define ") {
			append(&module.definitions, line)
		} else if strings.has_prefix(line, "%") {
			if at := strings.index(line, " = type "); at > 0 {
				module.named[line[:at]] = strings.trim_space(line[at + len(" = type "):])
			}
		}
	}
	return
}

// split_top splits text at a separator outside any bracket pair, dropping empty parts.
split_top :: proc(text: string, separator: byte) -> []string {
	parts := make([dynamic]string)
	depth, start := 0, 0
	for i in 0 ..< len(text) {
		switch text[i] {
		case '(', '<', '{', '[':
			depth += 1
		case ')', '>', '}', ']':
			depth -= 1
		case:
			if text[i] == separator && depth == 0 {
				if i > start { append(&parts, strings.trim_space(text[start:i])) }
				start = i + 1
			}
		}
	}
	if start < len(text) { append(&parts, strings.trim_space(text[start:])) }
	return parts[:]
}

is_type_start :: proc(token: string) -> bool {
	switch token {
	case "half", "float", "double", "ptr", "void":
		return true
	}
	if len(token) == 0 { return false }
	switch token[0] {
	case '{', '<', '[', '%':
		return true
	case 'i':
		_, ok := strconv.parse_int(token[1:])
		return ok
	}
	return false
}

element_bytes :: proc(text: string) -> int {
	switch text {
	case "half":
		return 2
	case "float":
		return 4
	case "double":
		return 8
	}
	bits, _ := strconv.parse_int(text[1:])
	return (bits + 7) / 8
}

flatten :: proc(type_text: string, named: map[string]string, out: ^[dynamic]string) {
	text := strings.trim_space(type_text)
	switch {
	case len(text) == 0 || text == "void":
	case text == "half":
		append(out, "S2")
	case text == "float":
		append(out, "S4")
	case text == "double":
		append(out, "S8")
	case text == "ptr":
		append(out, "I8")
	case text[0] == 'i':
		bits, _ := strconv.parse_int(text[1:])
		if bits == 128 {
			append(out, "I8@16", "I8")
		} else {
			append(out, fmt.tprintf("I%d", (bits + 7) / 8))
		}
	case strings.has_prefix(text, "<{"):
		for member in split_top(text[2:len(text) - 2], ',') { flatten(member, named, out) }
	case text[0] == '<':
		fields := split_top(text[1:len(text) - 1], ' ')
		count, _ := strconv.parse_int(fields[0])
		append(out, fmt.tprintf("S%d", count * element_bytes(fields[2])))
	case text[0] == '{':
		for member in split_top(text[1:len(text) - 1], ',') { flatten(member, named, out) }
	case text[0] == '[':
		fields := split_top(text[1:len(text) - 1], ' ')
		count, _ := strconv.parse_int(fields[0])
		for _ in 0 ..< count { flatten(strings.join(fields[2:], " "), named, out) }
	case text[0] == '%':
		if body, found := named[text]; found {
			flatten(body, named, out)
		} else {
			append(out, "?")
		}
	}
}

// describe_value renders one parameter or result (attributes and type tokens)
// into comparison tokens and returns its sign/zero extension attribute.
describe_value :: proc(tokens: []string, named: map[string]string, out: ^[dynamic]string) -> (ext: string) {
	type_index := -1
	for token, i in tokens {
		if is_type_start(token) {
			type_index = i
			break
		}
	}
	if type_index < 0 { return }
	byval, sret, align := false, false, 0
	for token, i in tokens {
		switch {
		case token == "zeroext":
			ext = "z"
		case token == "signext":
			ext = "s"
		case strings.has_prefix(token, "byval"):
			byval = true
		case strings.has_prefix(token, "sret"):
			sret = true
		case token == "align" && i + 1 < len(tokens):
			align, _ = strconv.parse_int(tokens[i + 1])
		}
	}
	switch {
	case sret:
		append(out, "SRET")
	case byval:
		append(out, fmt.tprintf("BV@%d", align))
	case:
		pieces := make([dynamic]string)
		flatten(tokens[type_index], named, &pieces)
		if len(pieces) == 1 && pieces[0][0] == 'I' { pieces[0] = fmt.tprintf("%s%s", pieces[0], ext) }
		append(out, ..pieces[:])
	}
	return
}

// signature_of renders a function definition as "params -> results" in the same
// form as canonical_plan. result_extension reports an extension attribute on the result.
signature_of :: proc(module: Module, name: string) -> (text: string, result_extension: bool, found: bool) {
	needle := fmt.tprintf("@%s(", name)
	for line in module.definitions {
		at := strings.index(line, needle)
		if at < 0 { continue }
		params := make([dynamic]string)
		results := make([dynamic]string)
		tail := line[at + len(needle):]
		depth, end := 1, 0
		for end = 0; end < len(tail) && depth > 0; end += 1 {
			switch tail[end] {
			case '(':
				depth += 1
			case ')':
				depth -= 1
			}
		}
		for param in split_top(tail[:end - 1], ',') {
			if param != "..." { describe_value(split_top(param, ' '), module.named, &params) }
		}
		result_extension = describe_value(split_top(line[len("define "):at], ' '), module.named, &results) != ""
		for &token in results { token = strip_result_marks(token) }
		return fmt.tprintf("%s -> %s", strings.join(params[:], " "), strings.join(results[:], " ")), result_extension, true
	}
	return "<missing>", false, false
}

// strip_result_marks removes the extension and stack-alignment marks that only
// parameters carry, so results compare by register class and size.
strip_result_marks :: proc(token: string) -> string {
	result := strings.trim_suffix(token, "@16")
	if strings.has_prefix(result, "I") && (strings.has_suffix(result, "z") || strings.has_suffix(result, "s")) {
		result = result[:len(result) - 1]
	}
	return result
}

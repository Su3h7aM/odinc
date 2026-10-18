package check

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

// Decodes one character of a quoted body as the official unquote_char does. quote is the byte that closes the
// literal; 0 leaves both quote bytes ordinary, as in a triple-quoted body.
@(private = "package")
literal_unquote_char :: proc(text: string, quote: byte) -> (r: rune, multiple_bytes: bool, tail: string, ok: bool) {
	if len(text) == 0 { return }
	if text[0] == quote && (quote == '\'' || quote == '"') { return }
	if text[0] >= 0x80 {
		width: int
		r, width = utf8.decode_rune_in_string(text)
		return r, true, text[width:], true
	}
	if text[0] != '\\' { return rune(text[0]), false, text[1:], true }
	if len(text) < 2 { return }
	escape := text[1]
	rest := text[2:]
	switch escape {
	case 'a':
		r = '\a'
	case 'b':
		r = '\b'
	case 'e':
		r = 0x1b
	case 'f':
		r = '\f'
	case 'n':
		r = '\n'
	case 'r':
		r = '\r'
	case 't':
		r = '\t'
	case 'v':
		r = '\v'
	case '\\', '\'', '"':
		r = rune(escape)
	case '0' ..= '7':
		if len(rest) < 2 { return }
		value := int(escape - '0')
		for index in 0 ..< 2 {
			digit := rest[index]
			if digit < '0' || digit > '7' { return }
			value = value << 3 | int(digit - '0')
		}
		if value > 0xff { return }
		r = rune(value)
		rest = rest[2:]
	case 'x', 'u', 'U':
		count := 2
		if escape == 'u' { count = 4 } else if escape == 'U' { count = 8 }
		if len(rest) < count { return }
		for index in 0 ..< count {
			digit := literal_hex_digit(rest[index])
			if digit < 0 { return }
			r = r << 4 | rune(digit)
		}
		rest = rest[count:]
		if escape != 'x' {
			if r > utf8.MAX_RUNE { return }
			multiple_bytes = true
		}
	case:
		return
	}
	return r, multiple_bytes, rest, true
}

@(private = "file")
literal_hex_digit :: proc(digit: byte) -> int {
	switch digit {
	case '0' ..= '9':
		return int(digit - '0')
	case 'a' ..= 'f':
		return int(digit - 'a') + 10
	case 'A' ..= 'F':
		return int(digit - 'A') + 10
	}
	return -1
}

// Decodes the escapes of a literal body. The result is always a new allocation.
@(private = "file")
literal_unescape :: proc(body: string, quote: byte, allocator: runtime.Allocator) -> (value: string, ok: bool, err: runtime.Allocator_Error) {
	buffer: [dynamic]byte
	buffer.allocator = allocator
	rest := body
	for len(rest) > 0 {
		r, multiple_bytes, tail, decoded := literal_unquote_char(rest, quote)
		if !decoded { return "", false, nil }
		rest = tail
		if r < 0x80 || !multiple_bytes {
			append(&buffer, byte(r)) or_return
		} else {
			encoded, width := utf8.encode_rune(r)
			append(&buffer, ..encoded[:width]) or_return
		}
	}
	return string(buffer[:]), true, nil
}

@(private = "file")
literal_strip_carriage_returns :: proc(body: string, allocator: runtime.Allocator) -> (value: string, ok: bool, err: runtime.Allocator_Error) {
	if strings.index_byte(body, '\r') < 0 { return body, true, nil }
	buffer: [dynamic]byte
	buffer.allocator = allocator
	for index in 0 ..< len(body) {
		if body[index] != '\r' { append(&buffer, body[index]) or_return }
	}
	return string(buffer[:]), true, nil
}

@(private = "file")
literal_is_blank_line :: proc(line: string) -> bool {
	for index in 0 ..< len(line) {
		if line[index] != ' ' && line[index] != '\t' { return false }
	}
	return true
}

// A triple-quoted literal opens and closes on its own lines. Each content line loses the indentation of the
// closing delimiter, blank lines become empty lines, and the escapes of `"""` bodies are then decoded.
@(private = "file")
literal_multiline_value :: proc(text: string, allocator: runtime.Allocator) -> (value: string, ok: bool, err: runtime.Allocator_Error) {
	if text[len(text) - 3:] != text[:3] { return "", false, nil }
	raw := text[0] == '`'
	body := text[3:len(text) - 3]
	first := strings.index_byte(body, '\n')
	if first < 0 {
		stripped, stripped_ok, strip_error := literal_strip_carriage_returns(body, allocator)
		if strip_error != nil || !stripped_ok || raw { return stripped, stripped_ok, strip_error }
		return literal_unescape(stripped, 0, allocator)
	}
	if !literal_is_blank_line(strings.trim_suffix(body[:first], "\r")) { return "", false, nil }
	last := strings.last_index_byte(body, '\n')
	indent := body[last + 1:]
	if !literal_is_blank_line(indent) { return "", false, nil }
	content := ""
	if last > first { content = body[first + 1:last] }

	buffer: [dynamic]byte
	buffer.allocator = allocator
	rest := content
	for {
		line_end := strings.index_byte(rest, '\n')
		line := rest
		if line_end >= 0 { line = rest[:line_end] }
		line = strings.trim_suffix(line, "\r")
		if !literal_is_blank_line(line) {
			if !strings.has_prefix(line, indent) { return "", false, nil }
			append(&buffer, ..transmute([]byte)line[len(indent):]) or_return
		}
		if line_end < 0 { break }
		append(&buffer, '\n') or_return
		rest = rest[line_end + 1:]
	}
	dedented := string(buffer[:])
	if raw { return dedented, true, nil }
	return literal_unescape(dedented, 0, allocator)
}

// Decodes the text of a string literal, quotes included. Raw and quoted literals follow odin.ebnf, and the
// escapes follow the official compiler. The value borrows the text when nothing needs decoding, and is
// otherwise allocated with allocator. ok is false for a malformed literal.
literal_string_value :: proc(text: string, allocator: runtime.Allocator) -> (value: string, ok: bool, err: runtime.Allocator_Error) {
	if len(text) >= 6 && text[0] == text[1] && text[1] == text[2] && (text[0] == '"' || text[0] == '`') {
		return literal_multiline_value(text, allocator)
	}
	if len(text) < 2 || text[len(text) - 1] != text[0] { return "", false, nil }
	body := text[1:len(text) - 1]
	switch text[0] {
	case '`':
		return literal_strip_carriage_returns(body, allocator)
	case '"':
		if strings.index_byte(body, '\n') >= 0 { return "", false, nil }
		if strings.index_byte(body, '\\') < 0 && strings.index_byte(body, '"') < 0 { return body, true, nil }
		return literal_unescape(body, '"', allocator)
	}
	return "", false, nil
}

package syntax

import "core:mem"
import "core:unicode"
import "core:unicode/utf8"

// Tokenizer scans a source buffer into tokens.
//
// It allocates nothing. `errors` and `comments` are optional caller-provided
// sinks; pass nil to discard one. A zero Tokenizer is inert but unusable; create
// one with `init`.
Tokenizer :: struct {
	// source is the buffer being scanned. It must outlive the tokenizer.
	source: []byte,

	// errors receives lexical errors in scan order when non-nil.
	errors: ^[dynamic]Error,
	// comments receives skipped comments in scan order when non-nil.
	comments: ^[dynamic]Comment,

	current_rune:   rune,
	current_offset: u32,
	next_offset:    u32,
	current_line:   u32,

	insert_semicolon: bool,
}

// init returns a Tokenizer over `source`.
//
// Lexical errors are appended to `errors` and skipped comments to `comments`.
// Pass nil for either to discard it; both sinks must use the caller's chosen
// allocator. A UTF-8 BOM at the start of the source is skipped.
init :: proc(source: []byte, errors: ^[dynamic]Error = nil, comments: ^[dynamic]Comment = nil) -> Tokenizer {
	tokenizer := Tokenizer {
		source       = source,
		errors       = errors,
		comments     = comments,
		current_line = 1,
	}
	advance_rune(&tokenizer)
	if tokenizer.current_rune == utf8.RUNE_BOM {
		advance_rune(&tokenizer)
	}
	return tokenizer
}

// next returns the next token and advances the tokenizer.
//
// Comments are skipped and recorded in the comment sink when one is set.
// Automatic semicolon insertion emits a `Semicolon` token whose `start == end`.
// Once the source is exhausted, `next` returns `EOF` forever.
next :: proc(tokenizer: ^Tokenizer) -> Token {
	had_backslash := false
	backslash_line := u32(0)

	for {
		skip_whitespace(tokenizer)
		start := tokenizer.current_offset
		start_line := tokenizer.current_line

		if tokenizer.current_rune == '/' && (peek_byte(tokenizer, 0) == '/' || peek_byte(tokenizer, 0) == '*') {
			scan_comment(tokenizer, start)
			continue
		}
		if tokenizer.current_rune == '#' && peek_byte(tokenizer, 0) == '!' {
			scan_line_comment(tokenizer, start)
			continue
		}

		if tokenizer.current_rune == '\\' {
			had_backslash = true
			backslash_line = start_line
			advance_rune(tokenizer)
			tokenizer.insert_semicolon = false
			continue
		}

		token := scan_token(tokenizer, start)
		if had_backslash && start_line == backslash_line {
			push_error(tokenizer, .Expected_Newline_After_Backslash, start)
		}
		return token
	}
}

@(private)
push_error :: proc(tokenizer: ^Tokenizer, kind: Error_Kind, offset: u32) {
	if tokenizer.errors != nil {
		append(tokenizer.errors, Error{kind = kind, offset = offset})
	}
}

@(private)
push_comment :: proc(tokenizer: ^Tokenizer, kind: Comment_Kind, start, end: u32) {
	if tokenizer.comments != nil {
		append(tokenizer.comments, Comment{start = start, end = end, kind = kind})
	}
}

@(private)
advance_rune :: proc(tokenizer: ^Tokenizer) {
	if tokenizer.next_offset < u32(len(tokenizer.source)) {
		if tokenizer.current_rune == '\n' {
			tokenizer.current_line += 1
		}
		tokenizer.current_offset = tokenizer.next_offset
		next_rune, width := utf8.decode_rune_in_bytes(tokenizer.source[tokenizer.next_offset:])
		tokenizer.next_offset += u32(width)
		tokenizer.current_rune = next_rune

		switch {
		case next_rune == 0:
			push_error(tokenizer, .Nul_Byte, tokenizer.current_offset)
		case next_rune == utf8.RUNE_ERROR && width == 1:
			push_error(tokenizer, .Illegal_Utf8, tokenizer.current_offset)
		case next_rune == utf8.RUNE_BOM && tokenizer.current_offset > 0:
			push_error(tokenizer, .Illegal_Bom, tokenizer.current_offset)
		}
	} else {
		if tokenizer.current_rune == '\n' {
			tokenizer.current_line += 1
		}
		tokenizer.current_offset = u32(len(tokenizer.source))
		tokenizer.current_rune = utf8.RUNE_EOF
	}
}

@(private)
peek_byte :: proc(tokenizer: ^Tokenizer, ahead: u32 = 0) -> byte {
	index := tokenizer.next_offset + ahead
	if index < u32(len(tokenizer.source)) {
		return tokenizer.source[index]
	}
	return 0
}

@(private)
peek_rune :: proc(tokenizer: ^Tokenizer, ahead: u32 = 0) -> rune {
	index := tokenizer.next_offset
	for _ in 0 ..< ahead {
		if index >= u32(len(tokenizer.source)) {
			return utf8.RUNE_EOF
		}
		_, width := utf8.decode_rune_in_bytes(tokenizer.source[index:])
		if width == 0 {
			return utf8.RUNE_EOF
		}
		index += u32(width)
	}
	if index >= u32(len(tokenizer.source)) {
		return utf8.RUNE_EOF
	}
	next_rune, _ := utf8.decode_rune_in_bytes(tokenizer.source[index:])
	return next_rune
}

@(private)
skip_whitespace :: proc(tokenizer: ^Tokenizer) {
	if tokenizer.insert_semicolon {
		for {
			switch tokenizer.current_rune {
			case ' ', '\t', '\r':
				advance_rune(tokenizer)
			case:
				return
			}
		}
	} else {
		for {
			switch tokenizer.current_rune {
			case ' ', '\t', '\r', '\n':
				advance_rune(tokenizer)
			case:
				return
			}
		}
	}
}

@(private)
is_letter :: proc(character: rune) -> bool {
	if character < utf8.RUNE_SELF {
		switch character {
		case '_':
			return true
		case 'A' ..= 'Z', 'a' ..= 'z':
			return true
		}
		return false
	}
	return unicode.is_letter(character)
}

@(private)
is_digit :: proc(character: rune) -> bool {
	if '0' <= character && character <= '9' {
		return true
	}
	if character < utf8.RUNE_SELF {
		return false
	}
	return unicode.is_digit(character)
}

@(private)
digit_value :: proc(character: rune) -> int {
	switch character {
	case '0' ..= '9':
		return int(character - '0')
	case 'A' ..= 'F':
		return int(character - 'A' + 10)
	case 'a' ..= 'f':
		return int(character - 'a' + 10)
	}
	return 16
}

@(private)
scan_comment :: proc(tokenizer: ^Tokenizer, start: u32) {
	if peek_byte(tokenizer, 0) == '/' {
		scan_line_comment(tokenizer, start)
		return
	}

	advance_rune(tokenizer)
	advance_rune(tokenizer)
	depth := 1
	for tokenizer.current_rune != utf8.RUNE_EOF {
		if tokenizer.current_rune == '/' && peek_byte(tokenizer, 0) == '*' {
			advance_rune(tokenizer)
			advance_rune(tokenizer)
			depth += 1
			continue
		}
		if tokenizer.current_rune == '*' && peek_byte(tokenizer, 0) == '/' {
			advance_rune(tokenizer)
			advance_rune(tokenizer)
			depth -= 1
			if depth == 0 {
				break
			}
			continue
		}
		advance_rune(tokenizer)
	}
	if depth != 0 {
		push_error(tokenizer, .Comment_Not_Terminated, start)
	}
	push_comment(tokenizer, .Block, start, tokenizer.current_offset)
}

@(private)
scan_line_comment :: proc(tokenizer: ^Tokenizer, start: u32) {
	for tokenizer.current_rune != '\n' && tokenizer.current_rune != utf8.RUNE_EOF {
		advance_rune(tokenizer)
	}
	push_comment(tokenizer, .Line, start, tokenizer.current_offset)
}

@(private)
scan_token :: proc(tokenizer: ^Tokenizer, start: u32) -> Token {
	first_rune := tokenizer.current_rune
	kind := Token_Kind.Invalid

	handled := false
	if is_letter(first_rune) {
		kind = scan_identifier(tokenizer)
		handled = true
	} else if '0' <= first_rune && first_rune <= '9' {
		kind = scan_number(tokenizer, false)
		handled = true
	}

	if !handled {
		advance_rune(tokenizer)
		switch first_rune {
		case utf8.RUNE_EOF:
			if tokenizer.insert_semicolon {
				tokenizer.insert_semicolon = false
				return Token{kind = .Semicolon, start = start, end = start}
			}
			kind = .EOF
		case '\n':
			tokenizer.insert_semicolon = false
			return Token{kind = .Semicolon, start = start, end = start}
		case '\'':
			kind = .Rune
			scan_rune(tokenizer, start)
		case '`', '"':
			kind = scan_string(tokenizer, start, first_rune)
		case '.':
			kind = .Period
			if tokenizer.current_rune == '.' {
				advance_rune(tokenizer)
				kind = .Ellipsis
				switch tokenizer.current_rune {
				case '<':
					advance_rune(tokenizer)
					kind = .Range_Half
				case '=':
					advance_rune(tokenizer)
					kind = .Range_Full
				}
			} else if '0' <= tokenizer.current_rune && tokenizer.current_rune <= '9' {
				kind = scan_number(tokenizer, true)
			}
		case '@':
			kind = .At
		case '$':
			kind = .Dollar
		case '?':
			kind = .Question
		case '^':
			kind = .Pointer
		case ';':
			kind = .Semicolon
		case ',':
			kind = .Comma
		case ':':
			kind = .Colon
		case '(':
			kind = .Open_Paren
		case ')':
			kind = .Close_Paren
		case '[':
			kind = .Open_Bracket
		case ']':
			kind = .Close_Bracket
		case '{':
			kind = .Open_Brace
		case '}':
			kind = .Close_Brace
		case '%':
			kind = .Mod
			switch tokenizer.current_rune {
			case '=':
				advance_rune(tokenizer)
				kind = .Mod_Eq
			case '%':
				advance_rune(tokenizer)
				kind = .Mod_Mod
				if tokenizer.current_rune == '=' {
					advance_rune(tokenizer)
					kind = .Mod_Mod_Eq
				}
			}
		case '*':
			kind = .Mul
			if tokenizer.current_rune == '=' {
				advance_rune(tokenizer)
				kind = .Mul_Eq
			} else if tokenizer.current_rune == '*' {
				advance_rune(tokenizer)
				kind = .Mul_Mul
			}
		case '=':
			kind = .Eq
			if tokenizer.current_rune == '=' {
				advance_rune(tokenizer)
				kind = .Cmp_Eq
			}
		case '~':
			kind = .Xor
			if tokenizer.current_rune == '=' {
				advance_rune(tokenizer)
				kind = .Xor_Eq
			}
		case '!':
			kind = .Not
			if tokenizer.current_rune == '=' {
				advance_rune(tokenizer)
				kind = .Not_Eq
			}
		case '+':
			kind = .Add
			switch tokenizer.current_rune {
			case '=':
				advance_rune(tokenizer)
				kind = .Add_Eq
			case '+':
				advance_rune(tokenizer)
				kind = .Increment
			}
		case '-':
			kind = .Sub
			switch tokenizer.current_rune {
			case '=':
				advance_rune(tokenizer)
				kind = .Sub_Eq
			case '-':
				advance_rune(tokenizer)
				kind = .Decrement
				if tokenizer.current_rune == '-' {
					advance_rune(tokenizer)
					kind = .Undef
				}
			case '>':
				advance_rune(tokenizer)
				kind = .Arrow_Right
			}
		case '#':
			kind = scan_directive(tokenizer)
		case '/':
			kind = .Quo
			if tokenizer.current_rune == '=' {
				advance_rune(tokenizer)
				kind = .Quo_Eq
			}
		case '<':
			kind = .Lt
			switch tokenizer.current_rune {
			case '=':
				advance_rune(tokenizer)
				kind = .Lt_Eq
			case '<':
				advance_rune(tokenizer)
				kind = .Shl
				if tokenizer.current_rune == '=' {
					advance_rune(tokenizer)
					kind = .Shl_Eq
				}
			}
		case '>':
			kind = .Gt
			switch tokenizer.current_rune {
			case '=':
				advance_rune(tokenizer)
				kind = .Gt_Eq
			case '>':
				advance_rune(tokenizer)
				kind = .Shr
				if tokenizer.current_rune == '=' {
					advance_rune(tokenizer)
					kind = .Shr_Eq
				}
			}
		case '&':
			kind = .And
			switch tokenizer.current_rune {
			case '~':
				advance_rune(tokenizer)
				kind = .And_Not
				if tokenizer.current_rune == '=' {
					advance_rune(tokenizer)
					kind = .And_Not_Eq
				}
			case '=':
				advance_rune(tokenizer)
				kind = .And_Eq
			case '&':
				advance_rune(tokenizer)
				kind = .Cmp_And
				if tokenizer.current_rune == '=' {
					advance_rune(tokenizer)
					kind = .Cmp_And_Eq
				}
			}
		case '|':
			kind = .Or
			switch tokenizer.current_rune {
			case '=':
				advance_rune(tokenizer)
				kind = .Or_Eq
			case '|':
				advance_rune(tokenizer)
				kind = .Cmp_Or
				if tokenizer.current_rune == '=' {
					advance_rune(tokenizer)
					kind = .Cmp_Or_Eq
				}
			}
		case:
			// A leading BOM is skipped by `init`, so one here was already reported.
			if first_rune != utf8.RUNE_BOM {
				push_error(tokenizer, .Unknown_Character, start)
			}
			kind = .Invalid
		}
	}

	apply_semicolon(tokenizer, kind, start)
	return Token{kind = kind, start = start, end = tokenizer.current_offset}
}

@(private)
scan_directive :: proc(tokenizer: ^Tokenizer) -> Token_Kind {
	if tokenizer.current_rune == '+' {
		for tokenizer.current_rune != utf8.RUNE_EOF {
			if tokenizer.current_rune == '\n' {
				break
			}
			if tokenizer.current_rune == '/' {
				following := peek_byte(tokenizer, 0)
				if following == '/' || following == '*' {
					break
				}
			}
			advance_rune(tokenizer)
		}
		return .Directive
	}
	if is_letter(tokenizer.current_rune) {
		for is_letter(tokenizer.current_rune) || is_digit(tokenizer.current_rune) {
			advance_rune(tokenizer)
		}
	}
	return .Directive
}

@(private)
apply_semicolon :: proc(tokenizer: ^Tokenizer, kind: Token_Kind, start: u32) {
	#partial switch kind {
	case .Invalid:
	case .Directive:
		// File tags and a lone '#' do not trigger insertion.
		trigger := false
		if start + 1 < u32(len(tokenizer.source)) {
			following := tokenizer.source[start + 1]
			if following == '_' || ('a' <= following && following <= 'z') || ('A' <= following && following <= 'Z') {
				trigger = true
			}
		}
		tokenizer.insert_semicolon = trigger
	case .Ident, .Context, .Typeid, .Break, .Continue, .Fallthrough, .Return,
	     .Integer, .Float, .Imag, .Rune, .String, .Raw_String, .Undef,
	     .Question, .Pointer, .Close_Paren, .Close_Bracket, .Close_Brace,
	     .Increment, .Decrement, .Not,
	     .Or_Return, .Or_Break, .Or_Continue:
		tokenizer.insert_semicolon = true
	case:
		tokenizer.insert_semicolon = false
	}
}

@(private)
scan_identifier :: proc(tokenizer: ^Tokenizer) -> Token_Kind {
	start := tokenizer.current_offset
	for is_letter(tokenizer.current_rune) || is_digit(tokenizer.current_rune) {
		advance_rune(tokenizer)
	}
	if kind, ok := keyword_kind(tokenizer.source[start:tokenizer.current_offset]); ok {
		return kind
	}
	return .Ident
}

@(private)
keyword_kind :: proc(name: []byte) -> (Token_Kind, bool) {
	// `fallthrough` is the longest keyword at 11 bytes.
	if len(name) < 2 || len(name) > 11 {
		return .Ident, false
	}
	switch string(name) {
	case "import":
		return .Import, true
	case "foreign":
		return .Foreign, true
	case "package":
		return .Package, true
	case "typeid":
		return .Typeid, true
	case "when":
		return .When, true
	case "where":
		return .Where, true
	case "if":
		return .If, true
	case "else":
		return .Else, true
	case "for":
		return .For, true
	case "switch":
		return .Switch, true
	case "in":
		return .In, true
	case "not_in":
		return .Not_In, true
	case "do":
		return .Do, true
	case "case":
		return .Case, true
	case "break":
		return .Break, true
	case "continue":
		return .Continue, true
	case "fallthrough":
		return .Fallthrough, true
	case "defer":
		return .Defer, true
	case "return":
		return .Return, true
	case "proc":
		return .Proc, true
	case "struct":
		return .Struct, true
	case "union":
		return .Union, true
	case "enum":
		return .Enum, true
	case "bit_set":
		return .Bit_Set, true
	case "bit_field":
		return .Bit_Field, true
	case "map":
		return .Map, true
	case "dynamic":
		return .Dynamic, true
	case "auto_cast":
		return .Auto_Cast, true
	case "cast":
		return .Cast, true
	case "transmute":
		return .Transmute, true
	case "distinct":
		return .Distinct, true
	case "using":
		return .Using, true
	case "context":
		return .Context, true
	case "or_else":
		return .Or_Else, true
	case "or_return":
		return .Or_Return, true
	case "or_break":
		return .Or_Break, true
	case "or_continue":
		return .Or_Continue, true
	case "asm":
		return .Asm, true
	case "matrix":
		return .Matrix, true
	}
	return .Ident, false
}

@(private)
scan_mantissa :: proc(tokenizer: ^Tokenizer, base: int) {
	for digit_value(tokenizer.current_rune) < base || tokenizer.current_rune == '_' {
		advance_rune(tokenizer)
	}
}

@(private)
scan_base_int :: proc(tokenizer: ^Tokenizer, base: int, error_kind: Error_Kind) -> Token_Kind {
	previous_offset := tokenizer.current_offset
	advance_rune(tokenizer)
	scan_mantissa(tokenizer, base)
	if tokenizer.current_offset - previous_offset <= 1 {
		push_error(tokenizer, error_kind, tokenizer.current_offset)
		return .Invalid
	}
	return .Integer
}

@(private)
scan_hex_float :: proc(tokenizer: ^Tokenizer) -> Token_Kind {
	previous_offset := tokenizer.current_offset
	advance_rune(tokenizer)
	scan_mantissa(tokenizer, 16)
	if tokenizer.current_offset - previous_offset <= 1 {
		push_error(tokenizer, .Invalid_Hexadecimal_Float, tokenizer.current_offset)
		return .Invalid
	}

	digit_count := 0
	i := previous_offset + 1
	for i < tokenizer.current_offset {
		if tokenizer.source[i] != '_' {
			digit_count += 1
		}
		i += 1
	}
	switch digit_count {
	case 4, 8, 16:
	case:
		push_error(tokenizer, .Invalid_Hexadecimal_Float, tokenizer.current_offset)
	}
	return .Float
}

@(private)
scan_fraction :: proc(tokenizer: ^Tokenizer, kind: ^Token_Kind) -> bool {
	if tokenizer.current_rune == '.' && peek_byte(tokenizer, 0) == '.' {
		return true
	}
	if tokenizer.current_rune == '.' {
		kind^ = .Float
		advance_rune(tokenizer)
		scan_mantissa(tokenizer, 10)
	}
	return false
}

@(private)
scan_exponent :: proc(tokenizer: ^Tokenizer, kind: ^Token_Kind) {
	if tokenizer.current_rune == 'e' || tokenizer.current_rune == 'E' {
		kind^ = .Float
		advance_rune(tokenizer)
		if tokenizer.current_rune == '-' || tokenizer.current_rune == '+' {
			advance_rune(tokenizer)
		}
		if digit_value(tokenizer.current_rune) < 10 {
			scan_mantissa(tokenizer, 10)
		} else {
			push_error(tokenizer, .Invalid_Float_Exponent, tokenizer.current_offset)
		}
	}
	switch tokenizer.current_rune {
	case 'i', 'j', 'k':
		kind^ = .Imag
		advance_rune(tokenizer)
	}
}

@(private)
scan_number :: proc(tokenizer: ^Tokenizer, seen_decimal_point: bool) -> Token_Kind {
	kind := Token_Kind.Integer

	if seen_decimal_point {
		kind = .Float
		scan_mantissa(tokenizer, 10)
		scan_exponent(tokenizer, &kind)
		return kind
	}

	if tokenizer.current_rune == '0' {
		advance_rune(tokenizer)
		switch tokenizer.current_rune {
		case 'b':
			kind = scan_base_int(tokenizer, 2, .Invalid_Binary_Integer)
		case 'o':
			kind = scan_base_int(tokenizer, 8, .Invalid_Octal_Integer)
		case 'd':
			kind = scan_base_int(tokenizer, 10, .Invalid_Decimal_Integer)
		case 'z':
			kind = scan_base_int(tokenizer, 12, .Invalid_Dozenal_Integer)
		case 'x':
			kind = scan_base_int(tokenizer, 16, .Invalid_Hexadecimal_Integer)
		case 'h':
			kind = scan_hex_float(tokenizer)
		case:
			scan_mantissa(tokenizer, 10)
			if scan_fraction(tokenizer, &kind) {
				return kind
			}
			scan_exponent(tokenizer, &kind)
			return kind
		}
	}

	scan_mantissa(tokenizer, 10)
	if scan_fraction(tokenizer, &kind) {
		return kind
	}
	scan_exponent(tokenizer, &kind)
	return kind
}

@(private)
scan_escape :: proc(tokenizer: ^Tokenizer, escape_offset: u32) -> bool {
	remaining: int
	base, maximum: u32
	switch tokenizer.current_rune {
	case 'a', 'b', 'e', 'f', 'n', 't', 'v', 'r', '\\', '\'', '\"':
		advance_rune(tokenizer)
		return true
	case '0' ..= '7':
		remaining, base, maximum = 3, 8, 255
	case 'x':
		advance_rune(tokenizer)
		remaining, base, maximum = 2, 16, 255
	case 'u':
		advance_rune(tokenizer)
		remaining, base, maximum = 4, 16, utf8.MAX_RUNE
	case 'U':
		advance_rune(tokenizer)
		remaining, base, maximum = 8, 16, utf8.MAX_RUNE
	case:
		if tokenizer.current_rune < 0 {
			push_error(tokenizer, .Escape_Not_Terminated, escape_offset)
		} else {
			push_error(tokenizer, .Unknown_Escape_Sequence, escape_offset)
		}
		return false
	}

	value: u32
	for remaining > 0 {
		digit := u32(digit_value(tokenizer.current_rune))
		if digit >= base {
			if tokenizer.current_rune < 0 {
				push_error(tokenizer, .Escape_Not_Terminated, tokenizer.current_offset)
			} else {
				push_error(tokenizer, .Illegal_Escape_Character, tokenizer.current_offset)
			}
			return false
		}
		value = value * base + digit
		advance_rune(tokenizer)
		remaining -= 1
	}
	if value > maximum || (0xd800 <= value && value <= 0xdfff) {
		push_error(tokenizer, .Invalid_Unicode_Code_Point, escape_offset)
		return false
	}
	return true
}

@(private)
scan_rune :: proc(tokenizer: ^Tokenizer, start: u32) {
	valid := true
	rune_count := 0
	for {
		current := tokenizer.current_rune
		if current == '\n' || current < 0 {
			if valid {
				push_error(tokenizer, .Rune_Not_Terminated, start)
				valid = false
			}
			break
		}
		advance_rune(tokenizer)
		if current == '\'' {
			break
		}
		rune_count += 1
		if current == '\\' {
			if !scan_escape(tokenizer, tokenizer.current_offset) {
				valid = false
			}
		}
	}
	if valid && rune_count != 1 {
		push_error(tokenizer, .Invalid_Rune_Literal, start)
	}
}

@(private)
scan_string :: proc(tokenizer: ^Tokenizer, start: u32, quote: rune) -> Token_Kind {
	if quote == '"' {
		if tokenizer.current_rune == '"' && peek_rune(tokenizer, 0) == '"' {
			advance_rune(tokenizer)
			advance_rune(tokenizer)
			for {
				current := tokenizer.current_rune
				if current < 0 {
					push_error(tokenizer, .Triple_String_Not_Terminated, start)
					break
				}
				advance_rune(tokenizer)
				if current == quote && tokenizer.current_rune == '"' && peek_rune(tokenizer, 0) == '"' {
					advance_rune(tokenizer)
					advance_rune(tokenizer)
					break
				}
				if current == '\\' {
					scan_escape(tokenizer, tokenizer.current_offset)
				}
			}
			return .String
		}
		for {
			current := tokenizer.current_rune
			if current == '\n' || current < 0 {
				push_error(tokenizer, .String_Not_Terminated, start)
				break
			}
			advance_rune(tokenizer)
			if current == quote {
				break
			}
			if current == '\\' {
				scan_escape(tokenizer, tokenizer.current_offset)
			}
		}
		return .String
	}

	if tokenizer.current_rune == '`' && peek_rune(tokenizer, 0) == '`' {
		advance_rune(tokenizer)
		advance_rune(tokenizer)
		for {
			current := tokenizer.current_rune
			if current < 0 {
				push_error(tokenizer, .Triple_String_Not_Terminated, start)
				break
			}
			advance_rune(tokenizer)
			if current == quote && tokenizer.current_rune == '`' && peek_rune(tokenizer, 0) == '`' {
				advance_rune(tokenizer)
				advance_rune(tokenizer)
				break
			}
		}
		return .Raw_String
	}
	for {
		current := tokenizer.current_rune
		if current < 0 {
			push_error(tokenizer, .Raw_String_Not_Terminated, start)
			break
		}
		advance_rune(tokenizer)
		if current == quote {
			break
		}
	}
	return .Raw_String
}

// Line_Table maps byte offsets to 1-based line and column numbers.
//
// Build one with `make_line_table` and release it with `destroy_line_table`. A
// zero Line_Table holds no memory; `destroy_line_table` on it is a no-op.
Line_Table :: struct {
	starts:    []u32,
	allocator: mem.Allocator,
}

// make_line_table records the start offset of every line in `source`, including
// a final start when the source ends in a newline.
//
// It allocates one slice with `allocator`. On success the returned Line_Table
// owns that slice and must be released with `destroy_line_table`.
make_line_table :: proc(source: []byte, allocator: mem.Allocator) -> (table: Line_Table, err: mem.Allocator_Error) #optional_allocator_error {
	count := 1
	for current_byte in source {
		if current_byte == '\n' {
			count += 1
		}
	}
	starts := make([]u32, count, allocator) or_return
	starts[0] = 0
	i := 1
	for current_byte, offset in source {
		if current_byte == '\n' {
			starts[i] = u32(offset) + 1
			i += 1
		}
	}
	return Line_Table{starts = starts, allocator = allocator}, .None
}

// destroy_line_table releases the storage owned by `table`. It is safe to call
// on a zero or already-destroyed Line_Table.
destroy_line_table :: proc(table: ^Line_Table) {
	if table.starts != nil {
		delete(table.starts, table.allocator)
		table.starts = nil
	}
	table.allocator = {}
}

// line_col returns the 1-based line and column of `offset` in `table`.
//
// It is `O(log n)` in the number of lines. An offset past the end of the source
// maps to the last line. A zero table maps every offset to `(1, offset+1)`.
line_col :: proc(table: Line_Table, offset: u32) -> (line: u32, column: u32) {
	starts := table.starts
	if len(starts) == 0 {
		return 1, offset + 1
	}

	low := 0
	high := len(starts)
	for low < high {
		middle := (low + high) / 2
		if starts[middle] <= offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	index := low - 1
	return u32(index) + 1, offset - starts[index] + 1
}

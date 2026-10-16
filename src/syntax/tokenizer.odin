// Single-pass tokenizer for Odin source.
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

	ch:          rune, // current rune
	offset:      u32,  // byte offset of `ch`
	read_offset: u32,  // byte offset just past `ch`
	line:        u32,  // 1-based line of `ch`

	insert_semicolon: bool,
}

// init returns a Tokenizer over `source`.
//
// Lexical errors are appended to `errors` and skipped comments to `comments`.
// Pass nil for either to discard it; both sinks must use the caller's chosen
// allocator. A UTF-8 BOM at the start of the source is skipped.
init :: proc(source: []byte, errors: ^[dynamic]Error = nil, comments: ^[dynamic]Comment = nil) -> Tokenizer {
	t := Tokenizer {
		source   = source,
		errors   = errors,
		comments = comments,
		line     = 1,
	}
	advance_rune(&t)
	if t.ch == utf8.RUNE_BOM {
		advance_rune(&t)
	}
	return t
}

// next returns the next token and advances the tokenizer.
//
// Comments are skipped and recorded in the comment sink when one is set.
// Automatic semicolon insertion emits a `Semicolon` token whose `start == end`.
// Once the source is exhausted, `next` returns `EOF` forever.
next :: proc(t: ^Tokenizer) -> Token {
	had_backslash := false
	backslash_line := u32(0)

	for {
		skip_whitespace(t)
		start := t.offset
		start_line := t.line

		// Comments are skipped but recorded.
		if t.ch == '/' && (peek_byte(t, 0) == '/' || peek_byte(t, 0) == '*') {
			scan_comment(t, start)
			continue
		}
		if t.ch == '#' && peek_byte(t, 0) == '!' {
			scan_line_comment(t, start)
			continue
		}

		// A backslash continues a logical line: the next token must begin on a
		// later line than the backslash.
		if t.ch == '\\' {
			had_backslash = true
			backslash_line = start_line
			advance_rune(t)
			t.insert_semicolon = false
			continue
		}

		tok := scan_token(t, start)
		if had_backslash && start_line == backslash_line {
			push_error(t, .Expected_Newline_After_Backslash, start)
		}
		return tok
	}
}

@(private)
push_error :: proc(t: ^Tokenizer, kind: Error_Kind, offset: u32) {
	if t.errors != nil {
		append(t.errors, Error{kind = kind, offset = offset})
	}
}

@(private)
push_comment :: proc(t: ^Tokenizer, kind: Comment_Kind, start, end: u32) {
	if t.comments != nil {
		append(t.comments, Comment{start = start, end = end, kind = kind})
	}
}

@(private)
advance_rune :: proc(t: ^Tokenizer) {
	if t.read_offset < u32(len(t.source)) {
		if t.ch == '\n' {
			t.line += 1
		}
		t.offset = t.read_offset
		r, w := utf8.decode_rune_in_bytes(t.source[t.read_offset:])
		t.read_offset += u32(w)
		t.ch = r

		switch {
		case r == 0:
			push_error(t, .Nul_Byte, t.offset)
		case r == utf8.RUNE_ERROR && w == 1:
			push_error(t, .Illegal_Utf8, t.offset)
		case r == utf8.RUNE_BOM && t.offset > 0:
			push_error(t, .Illegal_Bom, t.offset)
		}
	} else {
		if t.ch == '\n' {
			t.line += 1
		}
		t.offset = u32(len(t.source))
		t.ch = utf8.RUNE_EOF
	}
}

@(private)
peek_byte :: proc(t: ^Tokenizer, n: u32 = 0) -> byte {
	i := t.read_offset + n
	if i < u32(len(t.source)) {
		return t.source[i]
	}
	return 0
}

@(private)
peek_rune :: proc(t: ^Tokenizer, n: u32 = 0) -> rune {
	i := t.read_offset
	for _ in 0 ..< n {
		if i >= u32(len(t.source)) {
			return utf8.RUNE_EOF
		}
		_, w := utf8.decode_rune_in_bytes(t.source[i:])
		if w == 0 {
			return utf8.RUNE_EOF
		}
		i += u32(w)
	}
	if i >= u32(len(t.source)) {
		return utf8.RUNE_EOF
	}
	r, _ := utf8.decode_rune_in_bytes(t.source[i:])
	return r
}

@(private)
skip_whitespace :: proc(t: ^Tokenizer) {
	if t.insert_semicolon {
		// A pending semicolon is emitted at the newline, so stop there.
		for {
			switch t.ch {
			case ' ', '\t', '\r':
				advance_rune(t)
			case:
				return
			}
		}
	} else {
		for {
			switch t.ch {
			case ' ', '\t', '\r', '\n':
				advance_rune(t)
			case:
				return
			}
		}
	}
}

@(private)
is_letter :: proc(r: rune) -> bool {
	if r < utf8.RUNE_SELF {
		switch r {
		case '_':
			return true
		case 'A' ..= 'Z', 'a' ..= 'z':
			return true
		}
		return false
	}
	return unicode.is_letter(r)
}

@(private)
is_digit :: proc(r: rune) -> bool {
	if '0' <= r && r <= '9' {
		return true
	}
	if r < utf8.RUNE_SELF {
		return false
	}
	return unicode.is_digit(r)
}

@(private)
digit_val :: proc(r: rune) -> int {
	switch r {
	case '0' ..= '9':
		return int(r - '0')
	case 'A' ..= 'F':
		return int(r - 'A' + 10)
	case 'a' ..= 'f':
		return int(r - 'a' + 10)
	}
	return 16
}

@(private)
scan_comment :: proc(t: ^Tokenizer, start: u32) {
	if peek_byte(t, 0) == '/' {
		scan_line_comment(t, start)
		return
	}

	// A nestable block comment.
	advance_rune(t) // '/'
	advance_rune(t) // '*'
	nest := 1
	for t.ch != utf8.RUNE_EOF {
		if t.ch == '/' && peek_byte(t, 0) == '*' {
			advance_rune(t)
			advance_rune(t)
			nest += 1
			continue
		}
		if t.ch == '*' && peek_byte(t, 0) == '/' {
			advance_rune(t)
			advance_rune(t)
			nest -= 1
			if nest == 0 {
				break
			}
			continue
		}
		advance_rune(t)
	}
	if nest != 0 {
		push_error(t, .Comment_Not_Terminated, start)
	}
	push_comment(t, .Block, start, t.offset)
}

@(private)
scan_line_comment :: proc(t: ^Tokenizer, start: u32) {
	for t.ch != '\n' && t.ch != utf8.RUNE_EOF {
		advance_rune(t)
	}
	push_comment(t, .Line, start, t.offset)
}

@(private)
scan_token :: proc(t: ^Tokenizer, start: u32) -> Token {
	ch := t.ch
	kind := Token_Kind.Invalid

	handled := false
	if is_letter(ch) {
		kind = scan_identifier(t)
		handled = true
	} else if '0' <= ch && ch <= '9' {
		kind = scan_number(t, false)
		handled = true
	}

	if !handled {
		advance_rune(t)
		switch ch {
		case utf8.RUNE_EOF:
			if t.insert_semicolon {
				t.insert_semicolon = false
				return Token{kind = .Semicolon, start = start, end = start}
			}
			kind = .EOF
		case '\n':
			t.insert_semicolon = false
			return Token{kind = .Semicolon, start = start, end = start}
		case '\'':
			kind = .Rune
			scan_rune(t, start)
		case '`', '"':
			kind = scan_string(t, start, ch)
		case '.':
			kind = .Period
			if t.ch == '.' {
				advance_rune(t)
				kind = .Ellipsis
				switch t.ch {
				case '<':
					advance_rune(t)
					kind = .Range_Half
				case '=':
					advance_rune(t)
					kind = .Range_Full
				}
			} else if '0' <= t.ch && t.ch <= '9' {
				kind = scan_number(t, true)
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
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Mod_Eq
			case '%':
				advance_rune(t)
				kind = .Mod_Mod
				if t.ch == '=' {
					advance_rune(t)
					kind = .Mod_Mod_Eq
				}
			}
		case '*':
			kind = .Mul
			if t.ch == '=' {
				advance_rune(t)
				kind = .Mul_Eq
			} else if t.ch == '*' {
				advance_rune(t)
				kind = .Mul_Mul
			}
		case '=':
			kind = .Eq
			if t.ch == '=' {
				advance_rune(t)
				kind = .Cmp_Eq
			}
		case '~':
			kind = .Xor
			if t.ch == '=' {
				advance_rune(t)
				kind = .Xor_Eq
			}
		case '!':
			kind = .Not
			if t.ch == '=' {
				advance_rune(t)
				kind = .Not_Eq
			}
		case '+':
			kind = .Add
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Add_Eq
			case '+':
				advance_rune(t)
				kind = .Increment
			}
		case '-':
			kind = .Sub
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Sub_Eq
			case '-':
				advance_rune(t)
				kind = .Decrement
				if t.ch == '-' {
					advance_rune(t)
					kind = .Undef
				}
			case '>':
				advance_rune(t)
				kind = .Arrow_Right
			}
		case '#':
			kind = scan_directive(t)
		case '/':
			kind = .Quo
			if t.ch == '=' {
				advance_rune(t)
				kind = .Quo_Eq
			}
		case '<':
			kind = .Lt
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Lt_Eq
			case '<':
				advance_rune(t)
				kind = .Shl
				if t.ch == '=' {
					advance_rune(t)
					kind = .Shl_Eq
				}
			}
		case '>':
			kind = .Gt
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Gt_Eq
			case '>':
				advance_rune(t)
				kind = .Shr
				if t.ch == '=' {
					advance_rune(t)
					kind = .Shr_Eq
				}
			}
		case '&':
			kind = .And
			switch t.ch {
			case '~':
				advance_rune(t)
				kind = .And_Not
				if t.ch == '=' {
					advance_rune(t)
					kind = .And_Not_Eq
				}
			case '=':
				advance_rune(t)
				kind = .And_Eq
			case '&':
				advance_rune(t)
				kind = .Cmp_And
				if t.ch == '=' {
					advance_rune(t)
					kind = .Cmp_And_Eq
				}
			}
		case '|':
			kind = .Or
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Or_Eq
			case '|':
				advance_rune(t)
				kind = .Cmp_Or
				if t.ch == '=' {
					advance_rune(t)
					kind = .Cmp_Or_Eq
				}
			}
		case:
			// A BOM at the start is skipped by `init`; any other BOM is invalid.
			if ch != utf8.RUNE_BOM {
				push_error(t, .Unknown_Character, start)
			}
			kind = .Invalid
		}
	}

	apply_semicolon(t, kind, start)
	return Token{kind = kind, start = start, end = t.offset}
}

@(private)
scan_directive :: proc(t: ^Tokenizer) -> Token_Kind {
	// The leading '#' has already been consumed; `t.ch` is the rune after it.
	if t.ch == '+' {
		// A file tag such as `#+build` or `#+private`: runs to the end of the
		// line or to the start of a comment.
		for t.ch != utf8.RUNE_EOF {
			if t.ch == '\n' {
				break
			}
			if t.ch == '/' {
				next := peek_byte(t, 0)
				if next == '/' || next == '*' {
					break
				}
			}
			advance_rune(t)
		}
		return .Directive
	}
	if is_letter(t.ch) {
		for is_letter(t.ch) || is_digit(t.ch) {
			advance_rune(t)
		}
	}
	return .Directive
}

@(private)
apply_semicolon :: proc(t: ^Tokenizer, kind: Token_Kind, start: u32) {
	#partial switch kind {
	case .Invalid:
		// Preserve the pending semicolon, as the reference tokenizer does.
	case .Directive:
		// `#name` ends in an identifier and triggers insertion; `#+...` file tags
		// and a lone `#` do not.
		trigger := false
		if start + 1 < u32(len(t.source)) {
			b := t.source[start + 1]
			if b == '_' || ('a' <= b && b <= 'z') || ('A' <= b && b <= 'Z') {
				trigger = true
			}
		}
		t.insert_semicolon = trigger
	case .Ident, .Context, .Typeid, .Break, .Continue, .Fallthrough, .Return,
	     .Integer, .Float, .Imag, .Rune, .String, .Raw_String, .Undef,
	     .Question, .Pointer, .Close_Paren, .Close_Bracket, .Close_Brace,
	     .Increment, .Decrement, .Not,
	     .Or_Return, .Or_Break, .Or_Continue:
		t.insert_semicolon = true
	case:
		t.insert_semicolon = false
	}
}

@(private)
scan_identifier :: proc(t: ^Tokenizer) -> Token_Kind {
	start := t.offset
	for is_letter(t.ch) || is_digit(t.ch) {
		advance_rune(t)
	}
	if kind, ok := keyword_kind(t.source[start:t.offset]); ok {
		return kind
	}
	return .Ident
}

@(private)
keyword_kind :: proc(name: []byte) -> (Token_Kind, bool) {
	// Odin keywords are 2..11 bytes; the longest is `fallthrough`.
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
scan_mantissa :: proc(t: ^Tokenizer, base: int) {
	for digit_val(t.ch) < base || t.ch == '_' {
		advance_rune(t)
	}
}

@(private)
scan_base_int :: proc(t: ^Tokenizer, base: int, error_kind: Error_Kind) -> Token_Kind {
	prev := t.offset
	advance_rune(t) // the base letter
	scan_mantissa(t, base)
	if t.offset - prev <= 1 {
		push_error(t, error_kind, t.offset)
		return .Invalid
	}
	return .Integer
}

@(private)
scan_hex_float :: proc(t: ^Tokenizer) -> Token_Kind {
	prev := t.offset
	advance_rune(t) // 'h'
	scan_mantissa(t, 16)
	if t.offset - prev <= 1 {
		push_error(t, .Invalid_Hexadecimal_Float, t.offset)
		return .Invalid
	}

	digit_count := 0
	i := prev + 1
	for i < t.offset {
		if t.source[i] != '_' {
			digit_count += 1
		}
		i += 1
	}
	switch digit_count {
	case 4, 8, 16:
	case:
		push_error(t, .Invalid_Hexadecimal_Float, t.offset)
	}
	return .Float
}

@(private)
scan_fraction :: proc(t: ^Tokenizer, kind: ^Token_Kind) -> bool {
	if t.ch == '.' && peek_byte(t, 0) == '.' {
		return true
	}
	if t.ch == '.' {
		kind^ = .Float
		advance_rune(t)
		scan_mantissa(t, 10)
	}
	return false
}

@(private)
scan_exponent :: proc(t: ^Tokenizer, kind: ^Token_Kind) {
	if t.ch == 'e' || t.ch == 'E' {
		kind^ = .Float
		advance_rune(t)
		if t.ch == '-' || t.ch == '+' {
			advance_rune(t)
		}
		if digit_val(t.ch) < 10 {
			scan_mantissa(t, 10)
		} else {
			push_error(t, .Invalid_Float_Exponent, t.offset)
		}
	}
	switch t.ch {
	case 'i', 'j', 'k':
		kind^ = .Imag
		advance_rune(t)
	}
}

@(private)
scan_number :: proc(t: ^Tokenizer, seen_decimal_point: bool) -> Token_Kind {
	kind := Token_Kind.Integer

	if seen_decimal_point {
		kind = .Float
		scan_mantissa(t, 10)
		scan_exponent(t, &kind)
		return kind
	}

	if t.ch == '0' {
		advance_rune(t)
		switch t.ch {
		case 'b':
			kind = scan_base_int(t, 2, .Invalid_Binary_Integer)
		case 'o':
			kind = scan_base_int(t, 8, .Invalid_Octal_Integer)
		case 'd':
			kind = scan_base_int(t, 10, .Invalid_Decimal_Integer)
		case 'z':
			kind = scan_base_int(t, 12, .Invalid_Dozenal_Integer)
		case 'x':
			kind = scan_base_int(t, 16, .Invalid_Hexadecimal_Integer)
		case 'h':
			kind = scan_hex_float(t)
		case:
			scan_mantissa(t, 10)
			if scan_fraction(t, &kind) {
				return kind
			}
			scan_exponent(t, &kind)
			return kind
		}
	}

	scan_mantissa(t, 10)
	if scan_fraction(t, &kind) {
		return kind
	}
	scan_exponent(t, &kind)
	return kind
}

@(private)
scan_escape :: proc(t: ^Tokenizer, at: u32) -> bool {
	n: int
	base, max: u32
	switch t.ch {
	case 'a', 'b', 'e', 'f', 'n', 't', 'v', 'r', '\\', '\'', '\"':
		advance_rune(t)
		return true
	case '0' ..= '7':
		n, base, max = 3, 8, 255
	case 'x':
		advance_rune(t)
		n, base, max = 2, 16, 255
	case 'u':
		advance_rune(t)
		n, base, max = 4, 16, utf8.MAX_RUNE
	case 'U':
		advance_rune(t)
		n, base, max = 8, 16, utf8.MAX_RUNE
	case:
		if t.ch < 0 {
			push_error(t, .Escape_Not_Terminated, at)
		} else {
			push_error(t, .Unknown_Escape_Sequence, at)
		}
		return false
	}

	x: u32
	for n > 0 {
		d := u32(digit_val(t.ch))
		if d >= base {
			if t.ch < 0 {
				push_error(t, .Escape_Not_Terminated, t.offset)
			} else {
				push_error(t, .Illegal_Escape_Character, t.offset)
			}
			return false
		}
		x = x * base + d
		advance_rune(t)
		n -= 1
	}
	if x > max || (0xd800 <= x && x <= 0xdfff) {
		push_error(t, .Invalid_Unicode_Code_Point, at)
		return false
	}
	return true
}

@(private)
scan_rune :: proc(t: ^Tokenizer, start: u32) {
	// `t.ch` is the rune after the opening quote.
	valid := true
	n := 0
	for {
		ch := t.ch
		if ch == '\n' || ch < 0 {
			if valid {
				push_error(t, .Rune_Not_Terminated, start)
				valid = false
			}
			break
		}
		advance_rune(t)
		if ch == '\'' {
			break
		}
		n += 1
		if ch == '\\' {
			if !scan_escape(t, t.offset) {
				valid = false
			}
		}
	}
	if valid && n != 1 {
		push_error(t, .Invalid_Rune_Literal, start)
	}
}

@(private)
scan_string :: proc(t: ^Tokenizer, start: u32, quote: rune) -> Token_Kind {
	// `t.ch` is the rune after the opening quote.
	if quote == '"' {
		if t.ch == '"' && peek_rune(t, 0) == '"' {
			advance_rune(t) // the second opening quote
			advance_rune(t) // the third opening quote
			for {
				r := t.ch
				if r < 0 {
					push_error(t, .Triple_String_Not_Terminated, start)
					break
				}
				advance_rune(t)
				if r == quote && t.ch == '"' && peek_rune(t, 0) == '"' {
					advance_rune(t)
					advance_rune(t)
					break
				}
				if r == '\\' {
					scan_escape(t, t.offset)
				}
			}
			return .String
		}
		for {
			r := t.ch
			if r == '\n' || r < 0 {
				push_error(t, .String_Not_Terminated, start)
				break
			}
			advance_rune(t)
			if r == quote {
				break
			}
			if r == '\\' {
				scan_escape(t, t.offset)
			}
		}
		return .String
	}

	// A raw (backtick) string; escapes are not processed.
	if t.ch == '`' && peek_rune(t, 0) == '`' {
		advance_rune(t)
		advance_rune(t)
		for {
			r := t.ch
			if r < 0 {
				push_error(t, .Triple_String_Not_Terminated, start)
				break
			}
			advance_rune(t)
			if r == quote && t.ch == '`' && peek_rune(t, 0) == '`' {
				advance_rune(t)
				advance_rune(t)
				break
			}
		}
		return .Raw_String
	}
	for {
		r := t.ch
		if r < 0 {
			push_error(t, .Raw_String_Not_Terminated, start)
			break
		}
		advance_rune(t)
		if r == quote {
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
	// starts[i] is the byte offset of the first byte of line i+1; starts[0] == 0.
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
	for b in source {
		if b == '\n' {
			count += 1
		}
	}
	starts := make([]u32, count, allocator) or_return
	starts[0] = 0
	i := 1
	for b, offset in source {
		if b == '\n' {
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

	// Find the greatest i with starts[i] <= offset.
	lo := 0
	hi := len(starts)
	for lo < hi {
		mid := (lo + hi) / 2
		if starts[mid] <= offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	index := lo - 1
	return u32(index) + 1, offset - starts[index] + 1
}

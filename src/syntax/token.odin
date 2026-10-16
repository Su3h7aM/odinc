// Token kinds, the compact token value type, and lexical diagnostic types for
// the `syntax` package.
package syntax

// Token_Kind classifies a single lexical token.
//
// The `B_*` members delimit the three contiguous ranges of literal, operator,
// and keyword kinds. They are never produced by the tokenizer; use
// `is_literal`, `is_operator`, and `is_keyword` to test membership instead of
// comparing against them directly.
Token_Kind :: enum u16 {
	// Invalid is produced for a byte that begins no valid token.
	Invalid,
	// EOF is the final token of every stream.
	EOF,
	// Directive is a `#` directive: `#name`, a `#+...` file tag, or a lone `#`.
	// Its text is sliced from the source, e.g. `#partial` or `#+build`.
	Directive,

	B_Literal_Begin,
		// Ident is an identifier that is not a keyword.
		Ident,
		// Integer is a base-2/8/10/12/16 integer literal, e.g. `0b1010`, `0x1f`,
		// `1_000_000`.
		Integer,
		// Float is a decimal or hexadecimal floating-point literal.
		Float,
		// Imag is an imaginary literal ending in `i`, `j`, or `k`. These are the
		// component literals of complex and quaternion values, e.g. `2i`, `1.5j`.
		Imag,
		// Rune is a rune literal, e.g. `'a'`.
		Rune,
		// String is a double-quoted string literal, including `"""..."""`.
		String,
		// Raw_String is a backtick string literal, including triple-backtick.
		Raw_String,
	B_Literal_End,

	B_Operator_Begin,
		Eq, Not, At, Dollar, Pointer, Question,
		Add, Sub, Mul, Quo, Mod, Mod_Mod, And, Or, Xor, And_Not, Shl, Shr,
		Cmp_And, Cmp_Or, Mul_Mul,
		B_Assign_Op_Begin,
			Add_Eq, Sub_Eq, Mul_Eq, Quo_Eq, Mod_Eq, Mod_Mod_Eq,
			And_Eq, Or_Eq, Xor_Eq, And_Not_Eq, Shl_Eq, Shr_Eq,
			Cmp_And_Eq, Cmp_Or_Eq,
		B_Assign_Op_End,
		Increment, Decrement, Arrow_Right, Undef,
		B_Comparison_Begin,
			Cmp_Eq, Not_Eq, Lt, Gt, Lt_Eq, Gt_Eq,
		B_Comparison_End,
		Open_Paren, Close_Paren, Open_Bracket, Close_Bracket,
		Open_Brace, Close_Brace, Colon, Semicolon, Period, Comma,
		Ellipsis, Range_Half, Range_Full,
	B_Operator_End,

	B_Keyword_Begin,
		Import, Foreign, Package, Typeid, When, Where, If, Else, For,
		Switch, In, Not_In, Do, Case, Break, Continue, Fallthrough, Defer,
		Return, Proc, Struct, Union, Enum, Bit_Set, Bit_Field, Map, Dynamic,
		Auto_Cast, Cast, Transmute, Distinct, Using, Context, Or_Else,
		Or_Return, Or_Break, Or_Continue, Asm, Matrix,
	B_Keyword_End,

	COUNT,
}

// Token is a lexical token: its kind plus the half-open byte range `[start, end)`
// of its text within the source.
//
// The text itself is not stored. Slice it from the source with `token_text`, or
// use the offsets directly for a borrowed view. A token inserted by automatic
// semicolon insertion has `start == end`.
Token :: struct {
	kind:  Token_Kind,
	start: u32,
	end:   u32,
}

// Comment_Kind distinguishes the two comment forms.
Comment_Kind :: enum u8 {
	// Line is `// ...` or a `#!` shebang; it ends at the newline.
	Line,
	// Block is `/* ... */`; block comments nest.
	Block,
}

// Comment is the byte range of a comment that the tokenizer skipped.
Comment :: struct {
	start: u32,
	end:   u32,
	kind:  Comment_Kind,
}

// Error_Kind enumerates the lexical errors the tokenizer reports. The zero
// value `None` means "no error".
Error_Kind :: enum u8 {
	None,
	// Nul_Byte: a NUL byte appeared in the source.
	Nul_Byte,
	// Illegal_Utf8: a byte sequence did not decode as valid UTF-8.
	Illegal_Utf8,
	// Illegal_Bom: a byte order mark appeared after the start of the source.
	Illegal_Bom,
	// Unknown_Character: a byte began no valid token.
	Unknown_Character,
	// String_Not_Terminated: a `"..."` literal ran to a newline or EOF.
	String_Not_Terminated,
	// Triple_String_Not_Terminated: a `"""..."""` literal ran to EOF.
	Triple_String_Not_Terminated,
	// Raw_String_Not_Terminated: a backtick literal ran to EOF.
	Raw_String_Not_Terminated,
	// Rune_Not_Terminated: a rune literal ran to a newline or EOF.
	Rune_Not_Terminated,
	// Invalid_Rune_Literal: a rune literal did not hold exactly one rune.
	Invalid_Rune_Literal,
	// Comment_Not_Terminated: a block comment ran to EOF.
	Comment_Not_Terminated,
	// Unknown_Escape_Sequence: an escape began with an unknown character.
	Unknown_Escape_Sequence,
	// Escape_Not_Terminated: an escape ran to EOF.
	Escape_Not_Terminated,
	// Illegal_Escape_Character: an escape held a digit out of range for its base.
	Illegal_Escape_Character,
	// Invalid_Unicode_Code_Point: an escape encoded an invalid or surrogate value.
	Invalid_Unicode_Code_Point,
	// Invalid_Binary_Integer: a `0b` literal held no binary digit.
	Invalid_Binary_Integer,
	// Invalid_Octal_Integer: a `0o` literal held no octal digit.
	Invalid_Octal_Integer,
	// Invalid_Decimal_Integer: a `0d` literal held no decimal digit.
	Invalid_Decimal_Integer,
	// Invalid_Dozenal_Integer: a `0z` literal held no dozenal digit.
	Invalid_Dozenal_Integer,
	// Invalid_Hexadecimal_Integer: a `0x` literal held no hexadecimal digit.
	Invalid_Hexadecimal_Integer,
	// Invalid_Hexadecimal_Float: a `0h` literal was empty or did not hold exactly
	// 4, 8, or 16 hexadecimal digits.
	Invalid_Hexadecimal_Float,
	// Invalid_Float_Exponent: an `e`/`E` exponent held no decimal digit.
	Invalid_Float_Exponent,
	// Expected_Newline_After_Backslash: a `\` line continuation was followed by
	// a token on the same line.
	Expected_Newline_After_Backslash,
}

// Error is a lexical error located at a byte offset in the source.
Error :: struct {
	kind:   Error_Kind,
	offset: u32,
}

// is_literal reports whether `kind` is a literal kind (`Ident` through
// `Raw_String`).
is_literal :: proc(kind: Token_Kind) -> bool {
	return Token_Kind.B_Literal_Begin < kind && kind < Token_Kind.B_Literal_End
}

// is_operator reports whether `kind` is an operator or punctuation kind.
is_operator :: proc(kind: Token_Kind) -> bool {
	return Token_Kind.B_Operator_Begin < kind && kind < Token_Kind.B_Operator_End
}

// is_keyword reports whether `kind` is a keyword kind.
is_keyword :: proc(kind: Token_Kind) -> bool {
	return Token_Kind.B_Keyword_Begin < kind && kind < Token_Kind.B_Keyword_End
}

// token_text returns the source text of `token` as a borrowed string view. Nothing
// is allocated; `source` must be the buffer the token was scanned from.
//
// An inserted semicolon has an empty text.
token_text :: proc(source: []byte, token: Token) -> string {
	return string(source[token.start:token.end])
}

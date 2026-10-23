// Parser state, error values, token helpers, and the file and body entry points.
//
// Procedure names and order follow core:odin/parser so the two can be read side by side. Parsing
// never panics: a mismatch records a Parse_Error and returns a node or 0, and every loop consumes
// a token or stops at a closing token or EOF.
package syntax

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

Parse_Error_Kind :: enum u8 {
	Expected_Token,
	Expected_Operator,
	Expected_Operand,
	Expected_Type,
	Expected_Selector,
	Unsupported_Operator,
	Unknown_Directive,
	Unknown_Calling_Convention,
	Illegal_Directive_Combination,
	Invalid_Directive_Target,
	Duplicate_Directive,
	Missing_Matrix_Index,
	Spread_On_Field,
	Positional_After_Ellipsis,
	Missing_Poly_Parameter,
	Blank_Poly_Name,
	Invalid_Field,
	Unexpected_Prefix,
	Invalid_Proc_Signature,
	File_Scope_Statement,
	Misplaced_Statement,
	Expected_Statement,
	Expected_Single_Expression,
	Misplaced_Do_Body,
	Invalid_Value_Decl,
	Invalid_Attribute_Target,
	Invalid_Foreign_Declaration,
	Invalid_Unroll_Loop,
	Invalid_Asm_Operand,
	Invalid_Asm_Instruction,
	Invalid_Asm_Clobber,
	Invalid_Asm_Specification,
	Missing_Asm_Body,
	// Invalid_Feature_Flag is an unknown name in a #+feature tag. The official
	// text is "Invalid feature flag name: %s" followed by the expected list.
	Invalid_Feature_Flag,
	// Notted_Feature_Flag is `!` on a flag that forbids it. The official text
	// is "Feature flag does not support notting with '!' - '%s'".
	Notted_Feature_Flag,
	// Expected_Feature_Name is a bare `!` with no flag after it.
	Expected_Feature_Name,
	// Vet tag errors: official texts "Expected a space after #+vet", "Expected a vet flag name after '!'" and
	// "Invalid vet flag name".
	Expected_Space_After_Vet,
	Expected_Vet_Flag_Name,
	Invalid_Vet_Flag,
	// Conflicting_Feature_Flags is more than one integer-division-by-zero flag
	// on one #+feature line.
	Conflicting_Feature_Flags,
	// Expected_Space_After_Feature is a tag starting with #+feature but with no
	// space after it, e.g. #+featurex.
	Expected_Space_After_Feature,
	Disallowed_Do,
	Tabs_Required,
	Strict_Brace_Style,
	Unneeded_Semicolon,
	Trailing_Comma_Before_Closer,
	Out_Of_Memory,
}

// Parse_Error is a syntax error at a byte offset; `expected` is set for Expected_Token.
Parse_Error :: struct {
	kind:     Parse_Error_Kind,
	offset:   u32,
	expected: Token_Kind,
	// A name from the source that the text of the error quotes.
	detail:   string,
}

// Parser must not move after `parser_init`: the tokenizer keeps a pointer to `lex_errors`.
Parse_Options :: struct {
	disallow_do:  bool,
	// The command-line vet flags; `#+vet` tags and `vet_packages` change them per file.
	vet:          Vet_Flags,
	vet_packages: []string,
	strict_style: bool,
}

Parser :: struct {
	ast:              ^Ast,
	tokenizer:        Tokenizer,
	allocator:        mem.Allocator,
	prev:             Token,
	curr:             Token,
	errors:           [dynamic]Parse_Error,
	lex_errors:       [dynamic]Error,
	expr_level:       int,
	proc_depth:       int,
	allow_range:      bool,
	allow_in_expr:    bool,
	allow_type:       bool,
	in_foreign_block: bool,
	options:          Parse_Options,
	// The vet flags of the file being parsed.
	vet:              Vet_Flags,
}

parser_init :: proc(p: ^Parser, ast: ^Ast, source: []byte, allocator := context.allocator) {
	p^ = {}
	p.ast = ast
	p.allocator = allocator
	p.errors = make([dynamic]Parse_Error, allocator)
	p.lex_errors = make([dynamic]Error, allocator)
	p.tokenizer = init(source, &p.lex_errors, nil)
	p.curr = next(&p.tokenizer)
}

parser_destroy :: proc(p: ^Parser) {
	delete(p.errors)
	delete(p.lex_errors)
	p^ = {}
}

report :: proc(p: ^Parser, kind: Parse_Error_Kind, offset: u32, expected := Token_Kind.Invalid) {
	append(&p.errors, Parse_Error{kind = kind, offset = offset, expected = expected})
}

// The official text of a parse error that has one; empty for the rest.
parse_error_text :: proc(err: Parse_Error) -> string {
	#partial switch err.kind {
	case .Disallowed_Do:
		return "'do' has been disallowed"
	case .Tabs_Required:
		return "With '-vet-tabs', tabs must be used for indentation"
	case .Strict_Brace_Style:
		return "With '-strict-style' the attached brace style (1TBS) is enforced"
	case .Unneeded_Semicolon:
		return "Found unneeded semicolon"
	case .Expected_Space_After_Vet:
		return "Expected a space after #+vet"
	case .Expected_Vet_Flag_Name:
		return "Expected a vet flag name after '!'"
	case .Invalid_Vet_Flag:
		return fmt.tprintf("Invalid vet flag name: %s\n\tExpected one of the following\n%s", err.detail, VET_FLAG_NAMES)
	case .Trailing_Comma_Before_Closer:
		return fmt.tprintf("No need for a trailing comma followed by a %s on the same line", closer_text(err.expected))
	}
	return ""
}

VET_FLAG_NAMES :: "\tunused\n\tunused-variables\n\tunused-imports\n\tunused-procedures\n\tshadowing\n\tusing-stmt\n\tusing-param\n\tstyle\n\tsemicolon\n\tdeprecated\n\tcast\n\ttabs\n\texplicit-allocators\n\twhen-shadowing"

closer_text :: proc(kind: Token_Kind) -> string {
	#partial switch kind {
	case .Close_Brace:
		return "}"
	case .Close_Paren:
		return ")"
	}
	return "]"
}

push :: proc(p: ^Parser, list: ^$L/[dynamic]$E, value: E) {
	if _, err := append(list, value); err != nil {
		report(p, .Out_Of_Memory, p.curr.start)
	}
}

advance_token :: proc(p: ^Parser) -> Token {
	prev := p.curr
	p.prev = prev
	p.curr = next(&p.tokenizer)
	return prev
}

expect_token :: proc(p: ^Parser, kind: Token_Kind) -> Token {
	if p.curr.kind == kind {
		return advance_token(p)
	}
	report(p, .Expected_Token, p.curr.start, kind)
	return Token{kind = kind, start = p.curr.start, end = p.curr.start}
}

expect_closing :: proc(p: ^Parser, kind: Token_Kind) -> Token {
	if is_inserted_semicolon(p.curr) && peek_token(p, 0).kind == kind {
		advance_token(p)
	}
	return expect_token(p, kind)
}

// Only the `)` of parameter lists reports a trailing comma, as the official expect_token_after does.
check_trailing_comma :: proc(p: ^Parser, closing: Token_Kind) {
	if .Style in p.vet && p.curr.kind == closing && p.prev.kind == .Comma && !newline_before(p, p.curr) {
		report(p, .Trailing_Comma_Before_Closer, p.prev.start, closing)
	}
}

enforce_tab_indentation :: proc(p: ^Parser) {
	if .Tabs not_in p.vet || !newline_before(p, p.curr) { return }
	line_start := p.curr.start
	for line_start > 0 && p.tokenizer.source[line_start - 1] != '\n' { line_start -= 1 }
	for offset in line_start ..< p.curr.start {
		switch p.tokenizer.source[offset] {
		case '/':
			return
		case ' ':
			report(p, .Tabs_Required, p.curr.start)
			return
		}
	}
}

skip_possible_newline_before_brace :: proc(p: ^Parser, ignore_strict_style := false) {
	if !is_inserted_semicolon(p.curr) { return }
	next := peek_token(p, 0)
	if p.options.strict_style &&
	   !ignore_strict_style &&
	   (next.kind == .Open_Brace || next.kind == .Else) &&
	   strings.count(string(p.tokenizer.source[p.prev.end:next.start]), "\n") == 1 {
		report(p, .Strict_Brace_Style, next.start)
	}
	advance_token(p)
}

check_unneeded_semicolon :: proc(p: ^Parser) {
	semicolon := p.curr
	if !(p.options.strict_style || .Semicolon in p.vet) || semicolon.kind != .Semicolon || is_inserted_semicolon(semicolon) { return }
	next := peek_token(p, 0)
	if newline_between(p, semicolon.end, next.start) || next.kind == .EOF || next.kind == .Close_Brace || next.kind == .Close_Paren {
		report(p, .Unneeded_Semicolon, semicolon.start)
	}
}

allow_token :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	if p.curr.kind == kind {
		advance_token(p)
		return true
	}
	return false
}

// peek_token returns the token `lookahead + 1` positions after the current one without consuming.
peek_token :: proc(p: ^Parser, lookahead := 0) -> Token {
	scanner := p.tokenizer
	scanner.errors = nil
	token: Token
	for _ in 0 ..= lookahead {
		token = next(&scanner)
	}
	return token
}

is_inserted_semicolon :: proc(tok: Token) -> bool {
	return tok.kind == .Semicolon && tok.start == tok.end
}

newline_between :: proc(p: ^Parser, from, to: u32) -> bool {
	return strings.index_byte(string(p.tokenizer.source[from:to]), '\n') >= 0
}

// newline_before reports whether a line break separates the previous token from `tok`.
newline_before :: proc(p: ^Parser, tok: Token) -> bool {
	return newline_between(p, p.prev.end, tok.start)
}

node_text :: proc(p: ^Parser, index: Node_Index) -> string {
	node := p.ast.nodes[index]
	return string(p.tokenizer.source[node.start:node.end])
}

add_node :: proc(p: ^Parser, kind: Node_Kind, start, end: u32, payload: Node_Payload) -> Node_Index {
	return ast_add_node(p.ast, kind, start, end, payload)
}

// start_of returns the start of a node, or the current token's start for the none handle 0.
start_of :: proc(p: ^Parser, index: Node_Index) -> u32 {
	if index == 0 {
		return p.curr.start
	}
	return p.ast.nodes[index].start
}

is_blank_ident :: proc(p: ^Parser, index: Node_Index) -> bool {
	return index != 0 && p.ast.nodes[index].kind == .Ident && node_text(p, index) == "_"
}

parse_ident :: proc(p: ^Parser) -> Node_Index {
	tok := p.curr
	if tok.kind != .Ident {
		expect_token(p, .Ident)
		return add_node(p, .Ident, tok.start, tok.start, Ident{})
	}
	advance_token(p)
	return add_node(p, .Ident, tok.start, tok.end, Ident{})
}

// Feature_Flag is one opt-in language feature from a #+feature file tag. The set
// mirrors the official compiler (build_settings.cpp get_feature_flag_from_name).
Feature_Flag :: enum {
	Dynamic_Literals,
	Global_Context,
	Division_Trap,
	Division_Zero,
	Division_Self,
	Division_All_Bits,
	Force_Type_Assert,
	Using_Stmt,
}

Feature_Flags :: bit_set[Feature_Flag;u8]

feature_flag_from_name :: proc(name: string) -> (Feature_Flag, bool) {
	switch name {
	case "dynamic-literals":
		return .Dynamic_Literals, true
	case "global-context":
		return .Global_Context, true
	case "integer-division-by-zero:trap":
		return .Division_Trap, true
	case "integer-division-by-zero:zero":
		return .Division_Zero, true
	case "integer-division-by-zero:self":
		return .Division_Self, true
	case "integer-division-by-zero:all-bits":
		return .Division_All_Bits, true
	case "force-type-assert":
		return .Force_Type_Assert, true
	case "using-stmt":
		return .Using_Stmt, true
	}
	return {}, false
}

// next_flag_name splits one flag name off the front of a #+feature tag body,
// mirroring vet_tag_get_token with allow_colon in the official parser: names hold
// letters, digits, '-' and ':', with '!' allowed only first. Anything else ends
// the name, and a leading separator is its own token.
next_flag_name :: proc(body: string, allow_colon: bool) -> (name, rest: string) {
	trimmed := strings.trim_space(body)
	offset := 0
	for offset < len(trimmed) {
		char, width := utf8.decode_rune_in_string(trimmed[offset:])
		if offset == 0 && char == '!' {
			// Consumed below.
		} else if !is_letter(char) && !is_digit(char) && char != '-' && !(allow_colon && char == ':') {
			if offset == 0 {
				return trimmed[:width], trimmed[width:]
			}
			return trimmed[:offset], trimmed[offset:]
		}
		offset += width
	}
	return trimmed, ""
}

// validate_feature_tag rejects unknown #+feature flag names at parse time, like
// the official parser.cpp parse_feature_tag. The error offset is the tag start,
// matching the official span. force-type-assert is valid here although the
// official suggestion list omits it.
validate_feature_tag :: proc(p: ^Parser, start: u32, text: string) {
	body := text[len("#+feature"):]
	if len(body) == 0 {
		return
	}
	if body[0] != ' ' {
		if strings.trim_space(body) != "" {
			report(p, .Expected_Space_After_Feature, start)
		}
		return
	}
	enabled, disabled: Feature_Flags
	for len(strings.trim_space(body)) > 0 {
		name: string
		name, body = next_flag_name(body, true)
		name = strings.trim_space(name)
		if len(name) == 0 {
			break
		}
		flag_name := name
		notted := false
		if flag_name[0] == '!' {
			notted = true
			flag_name = flag_name[1:]
			if len(flag_name) == 0 {
				report(p, .Expected_Feature_Name, start)
				return
			}
		}
		flag, ok := feature_flag_from_name(flag_name)
		if !ok {
			report(p, .Invalid_Feature_Flag, start)
			return
		}
		if notted {
			// The official compiler rejects `!` on trap, zero and all-bits but
			// accepts it on self.
			switch flag {
			case .Division_Trap, .Division_Zero, .Division_All_Bits:
				report(p, .Notted_Feature_Flag, start)
			case .Dynamic_Literals, .Global_Context, .Division_Self, .Force_Type_Assert, .Using_Stmt:
			}
			disabled += {flag}
		} else {
			enabled += {flag}
		}
	}
	divisions := (enabled - disabled) & {.Division_Trap, .Division_Zero, .Division_Self, .Division_All_Bits}
	if card(divisions) > 1 {
		report(p, .Conflicting_Feature_Flags, start)
	}
}

// apply_vet_tag applies a `#+vet` tag to the vet flags of the file, as the official parse_vet_tag does.
apply_vet_tag :: proc(p: ^Parser, start: u32, text: string) {
	flags, err, invalid_name := parse_vet_tag(text[len("#+vet"):], p.vet)
	switch err {
	case .None:
	case .Expected_Space:
		report(p, .Expected_Space_After_Vet, start)
	case .Expected_Flag_Name:
		report(p, .Expected_Vet_Flag_Name, start)
	case .Invalid_Flag:
		report(p, .Invalid_Vet_Flag, start)
		p.errors[len(p.errors) - 1].detail = invalid_name
	}
	p.vet = flags
}

// parse_file parses the file header, then statements up to EOF, and sets `ast.root`.
parse_file :: proc(p: ^Parser) -> Node_Index {
	tags := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(tags)
	p.vet = p.options.vet
	tagged := false
	for p.curr.kind != .Package && p.curr.kind != .EOF {
		start := p.curr.start
		if p.curr.kind != .Directive || !strings.has_prefix(token_text(p.tokenizer.source, p.curr), "#+") {
			report(p, .Expected_Token, start, .Package)
			advance_token(p)
			continue
		}
		advance_token(p)
		push(p, &tags, add_node(p, .File_Tag, start, p.prev.end, File_Tag{}))
		text := token_text(p.tokenizer.source, p.prev)
		if strings.has_prefix(text, "#+feature") {
			validate_feature_tag(p, start, text)
		} else if strings.has_prefix(text, "#+vet") {
			apply_vet_tag(p, start, text)
			tagged = true
		}
		expect_semicolon(p, 0)
	}

	package_pos := expect_token(p, .Package).start
	name := parse_ident(p)
	if !tagged { p.vet = vet_flags_for_package(p.options, node_text(p, name)) }
	p.ast.vet = p.vet
	package_decl := add_node(p, .Package_Decl, package_pos, p.prev.end, Package_Decl{package_pos = package_pos, name = name})
	expect_semicolon(p, package_decl)

	decls := make([dynamic]Node_Index, 0, 16, p.allocator)
	defer delete(decls)
	for p.curr.kind != .EOF {
		decl := parse_stmt(p)
		if p.ast.nodes[decl].kind != .Empty_Stmt {
			push(p, &decls, decl)
		}
	}

	file := add_node(
		p,
		.File,
		0,
		u32(len(p.tokenizer.source)),
		File{tags = ast_add_list(p.ast, tags[:]), package_decl = package_decl, decls = ast_add_list(p.ast, decls[:])},
	)
	p.ast.root = file
	if p.ast.allocation_error != nil {
		report(p, .Out_Of_Memory, 0)
	}
	return file
}

parse_body :: proc(p: ^Parser) -> Node_Index {
	prev_expr_level := p.expr_level
	defer p.expr_level = prev_expr_level
	p.expr_level = 0

	open := expect_token(p, .Open_Brace)
	stmts := parse_stmt_list(p)
	close := expect_token(p, .Close_Brace)

	return add_node(p, .Block_Stmt, open.start, p.prev.end, Block_Stmt{open = open.start, stmts = stmts, close = close.start})
}

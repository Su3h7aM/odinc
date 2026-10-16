// Parser state, error values, token helpers and the file, body and statement-stub entry points.
//
// Procedure names and order follow core:odin/parser so the two can be read side by side. Parsing
// never panics: a mismatch records a Parse_Error and returns a node or 0, and every loop consumes
// a token or stops at a closing token or EOF.
package syntax

import "core:mem"
import "core:strings"

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
	Unsupported_Construct,
}

// Parse_Error is a syntax error at a byte offset; `expected` is set for Expected_Token.
Parse_Error :: struct {
	kind:     Parse_Error_Kind,
	offset:   u32,
	expected: Token_Kind,
}

// Parser must not move after `parser_init`: the tokenizer keeps a pointer to `lex_errors`.
Parser :: struct {
	ast:              ^Ast,
	tokenizer:        Tokenizer,
	allocator:        mem.Allocator,
	prev:             Token,
	curr:             Token,
	errors:           [dynamic]Parse_Error,
	lex_errors:       [dynamic]Error,
	expr_level:       int,
	allow_range:      bool,
	allow_in_expr:    bool,
	allow_type:       bool,
	in_foreign_block: bool,
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

expect_semicolon :: proc(p: ^Parser) {
	if p.curr.kind == .Semicolon {
		advance_token(p)
	} else if p.curr.kind != .EOF {
		report(p, .Expected_Token, p.curr.start, .Semicolon)
	}
}

// parse_file parses the file header, then statements up to EOF, and sets `ast.root`.
parse_file :: proc(p: ^Parser) -> Node_Index {
	tags := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(tags)
	for p.curr.kind != .Package && p.curr.kind != .EOF {
		start := p.curr.start
		if p.curr.kind != .Directive || !strings.has_prefix(token_text(p.tokenizer.source, p.curr), "#+") {
			report(p, .Expected_Token, start, .Package)
			advance_token(p)
			continue
		}
		advance_token(p)
		for p.curr.kind != .Semicolon && p.curr.kind != .EOF && p.curr.kind != .Package {
			advance_token(p)
		}
		append(&tags, add_node(p, .File_Tag, start, p.prev.end, File_Tag{}))
		expect_semicolon(p)
	}

	package_pos := expect_token(p, .Package).start
	name := parse_ident(p)
	package_decl := add_node(p, .Package_Decl, package_pos, p.prev.end, Package_Decl{package_pos = package_pos, name = name})
	expect_semicolon(p)

	decls := make([dynamic]Node_Index, 0, 16, p.allocator)
	defer delete(decls)
	for p.curr.kind != .EOF {
		append(&decls, parse_stmt_stub(p))
	}

	file := add_node(p, .File, 0, u32(len(p.tokenizer.source)), File{
		tags         = ast_add_list(p.ast, tags[:]),
		package_decl = package_decl,
		decls        = ast_add_list(p.ast, decls[:]),
	})
	p.ast.root = file
	return file
}

// parse_stmt_stub stands in for statements until stage B. It records one error and skips to the
// next statement boundary, always consuming at least one token unless at EOF.
parse_stmt_stub :: proc(p: ^Parser) -> Node_Index {
	start := p.curr.start
	report(p, .Unsupported_Construct, start)
	if p.curr.kind != .EOF {
		advance_token(p)
	}
	for p.curr.kind != .EOF && p.curr.kind != .Close_Brace && p.curr.kind != .Semicolon {
		advance_token(p)
	}
	if p.curr.kind == .Semicolon {
		advance_token(p)
	}
	return add_node(p, .Bad_Stmt, start, p.prev.end, Bad_Stmt{})
}

parse_body :: proc(p: ^Parser) -> Node_Index {
	prev_expr_level := p.expr_level
	defer p.expr_level = prev_expr_level
	p.expr_level = 0

	open := expect_token(p, .Open_Brace)
	stmts := make([dynamic]Node_Index, 0, 8, p.allocator)
	defer delete(stmts)
	for p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
		append(&stmts, parse_stmt_stub(p))
	}
	close := expect_token(p, .Close_Brace)

	return add_node(p, .Block_Stmt, open.start, p.prev.end, Block_Stmt{
		open  = open.start,
		stmts = ast_add_list(p.ast, stmts[:]),
		close = close.start,
	})
}

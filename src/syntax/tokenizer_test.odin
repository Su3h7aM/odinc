package syntax

import "core:mem"
import odin_tokenizer "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(private = "file")
as_bytes :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

@(private = "file")
scan_all :: proc(source: []byte, tokens: ^[dynamic]Token, errors: ^[dynamic]Error = nil, comments: ^[dynamic]Comment = nil) {
	tokenizer := init(source, errors, comments)
	for {
		token := next(&tokenizer)
		append(tokens, token)
		if token.kind == .EOF {
			break
		}
	}
}

@(private = "file")
expect_kinds :: proc(test: ^testing.T, source: string, want: []Token_Kind) {
	errors: [dynamic]Error
	tokens: [dynamic]Token
	defer delete(errors)
	defer delete(tokens)

	scan_all(transmute([]byte)source, &tokens, &errors)
	testing.expectf(test, len(errors) == 0, "%q: unexpected errors %v", source, errors)
	testing.expectf(test, len(tokens) == len(want), "%q: got %d tokens, want %d", source, len(tokens), len(want))

	limit := min(len(tokens), len(want))
	for i in 0 ..< limit {
		if tokens[i].kind != want[i] {
			testing.expectf(test, false, "%q: token %d is %v, want %v", source, i, tokens[i].kind, want[i])
			return
		}
	}
}

@(test)
test_token_spans :: proc(test: ^testing.T) {
	source := as_bytes("foo bar")
	tokens: [dynamic]Token
	defer delete(tokens)
	scan_all(source, &tokens)

	testing.expect_value(test, len(tokens), 4)
	testing.expect_value(test, token_text(source, tokens[0]), "foo")
	testing.expect_value(test, tokens[0].start, u32(0))
	testing.expect_value(test, tokens[0].end, u32(3))
	testing.expect_value(test, token_text(source, tokens[1]), "bar")
	testing.expect_value(test, tokens[1].start, u32(4))
	testing.expect_value(test, tokens[1].end, u32(7))
}

@(test)
test_non_ascii_identifier_spans :: proc(test: ^testing.T) {
	source := as_bytes("na\u00efve if x")
	tokens: [dynamic]Token
	defer delete(tokens)
	scan_all(source, &tokens)

	testing.expect_value(test, len(tokens), 5)
	if len(tokens) < 3 { return }
	testing.expect_value(test, token_text(source, tokens[0]), "na\u00efve")
	testing.expect_value(test, tokens[0].end, u32(6))
	testing.expect_value(test, tokens[1].kind, Token_Kind.If)
	testing.expect_value(test, token_text(source, tokens[1]), "if")
	testing.expect_value(test, token_text(source, tokens[2]), "x")
	testing.expect_value(test, tokens[2].start, u32(10))
}

@(test)
test_semicolon_insertion :: proc(test: ^testing.T) {
	cases := []struct {
		source: string,
		kinds:  []Token_Kind,
	} {
		{"", {.EOF}},
		{"a", {.Ident, .Semicolon, .EOF}},
		{"a\n", {.Ident, .Semicolon, .EOF}},
		{"a\nb", {.Ident, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"1\n2", {.Integer, .Semicolon, .Integer, .Semicolon, .EOF}},
		{"return\nnext", {.Return, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x)\ny", {.Ident, .Close_Paren, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x]\ny", {.Ident, .Close_Bracket, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x}\ny", {.Ident, .Close_Brace, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x^\ny", {.Ident, .Pointer, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x?\ny", {.Ident, .Question, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x++\ny", {.Ident, .Increment, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x--\ny", {.Ident, .Decrement, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x---\ny", {.Ident, .Undef, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x!\ny", {.Ident, .Not, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x +\ny", {.Ident, .Add, .Ident, .Semicolon, .EOF}},
		{"x // comment\ny", {.Ident, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x /* a /* b */ c */\ny", {.Ident, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x;\ny", {.Ident, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x \\\ny", {.Ident, .Ident, .Semicolon, .EOF}},
		{"\xEF\xBB\xBFa", {.Ident, .Semicolon, .EOF}},
	}

	for test_case in cases {
		expect_kinds(test, test_case.source, test_case.kinds)
	}
}

@(test)
test_comments_recorded :: proc(test: ^testing.T) {
	source := as_bytes("a // one\n/* two */ b")
	tokens: [dynamic]Token
	comments: [dynamic]Comment
	errors: [dynamic]Error
	defer delete(tokens)
	defer delete(comments)
	defer delete(errors)
	scan_all(source, &tokens, &errors, &comments)

	testing.expect_value(test, len(errors), 0)
	testing.expect_value(test, len(comments), 2)
	if len(comments) == 2 {
		testing.expect_value(test, comments[0].kind, Comment_Kind.Line)
		testing.expect_value(test, comments[0].start, u32(2))
		testing.expect_value(test, comments[0].end, u32(8))
		testing.expect_value(test, comments[1].kind, Comment_Kind.Block)
		testing.expect_value(test, comments[1].start, u32(9))
		testing.expect_value(test, comments[1].end, u32(18))
	}
}

@(test)
test_errors :: proc(test: ^testing.T) {
	cases := []struct {
		source: string,
		kind:   Error_Kind,
		offset: u32,
	} {
		{"\"unterminated", .String_Not_Terminated, 0},
		{"\"\"\"unterminated", .Triple_String_Not_Terminated, 0},
		{"`unterminated", .Raw_String_Not_Terminated, 0},
		{"'a", .Rune_Not_Terminated, 0},
		{"'ab'", .Invalid_Rune_Literal, 0},
		{"/* unterminated", .Comment_Not_Terminated, 0},
		{"\"\\q\"", .Unknown_Escape_Sequence, 2},
		{"\"\\uD800\"", .Invalid_Unicode_Code_Point, 2},
		{"0b", .Invalid_Binary_Integer, 2},
		{"0o", .Invalid_Octal_Integer, 2},
		{"0d", .Invalid_Decimal_Integer, 2},
		{"0z", .Invalid_Dozenal_Integer, 2},
		{"0x", .Invalid_Hexadecimal_Integer, 2},
		{"0hxyz", .Invalid_Hexadecimal_Float, 2},
		{"1e", .Invalid_Float_Exponent, 2},
		{"a\x00b", .Nul_Byte, 1},
		{"\xff", .Illegal_Utf8, 0},
	}

	for test_case in cases {
		errors: [dynamic]Error
		tokens: [dynamic]Token
		scan_all(transmute([]byte)test_case.source, &tokens, &errors)

		found := false
		for reported in errors {
			if reported.kind == test_case.kind && reported.offset == test_case.offset {
				found = true
			}
		}
		testing.expectf(test, found, "%q: expected error %v at %d, got %v", test_case.source, test_case.kind, test_case.offset, errors)
		delete(errors)
		delete(tokens)
	}
}

@(test)
test_line_col :: proc(test: ^testing.T) {
	source := as_bytes("ab\ncde\n")
	table, err := make_line_table(source, context.allocator)
	defer destroy_line_table(&table)
	testing.expect_value(test, err, mem.Allocator_Error.None)

	cases := []struct {
		offset: u32,
		line:   u32,
		column: u32,
	}{{0, 1, 1}, {1, 1, 2}, {3, 2, 1}, {5, 2, 3}, {6, 2, 4}, {7, 3, 1}}
	for test_case in cases {
		line, column := line_col(table, test_case.offset)
		testing.expectf(
			test,
			line == test_case.line && column == test_case.column,
			"offset %d: got %d:%d, want %d:%d",
			test_case.offset,
			line,
			column,
			test_case.line,
			test_case.column,
		)
	}
}

// Broad classes for comparing against the reference tokenizer.
@(private = "file")
Class :: enum {
	Other,
	EOF,
	Directive,
	Ident,
	Literal,
	Keyword,
	Operator,
	Semicolon,
}

@(private = "file")
class_actual :: proc(kind: Token_Kind) -> Class {
	switch {
	case kind == .Invalid:
		return .Other
	case kind == .EOF:
		return .EOF
	case kind == .Directive:
		return .Directive
	case kind == .Ident:
		return .Ident
	case kind == .Integer, kind == .Float, kind == .Imag, kind == .Rune, kind == .String, kind == .Raw_String:
		return .Literal
	case kind == .Semicolon:
		return .Semicolon
	case Token_Kind.B_Operator_Begin < kind && kind < Token_Kind.B_Operator_End:
		return .Operator
	case Token_Kind.B_Keyword_Begin < kind && kind < Token_Kind.B_Keyword_End:
		return .Keyword
	}
	return .Other
}

@(private = "file")
class_reference :: proc(kind: odin_tokenizer.Token_Kind) -> Class {
	switch {
	case kind == .Invalid:
		return .Other
	case kind == .EOF:
		return .EOF
	case kind == .File_Tag, kind == .Hash:
		return .Directive
	case kind == .Ident:
		return .Ident
	case kind == .Integer, kind == .Float, kind == .Imag, kind == .Rune, kind == .String:
		return .Literal
	case kind == .Semicolon:
		return .Semicolon
	case odin_tokenizer.Token_Kind.B_Operator_Begin < kind && kind < odin_tokenizer.Token_Kind.B_Operator_End:
		return .Operator
	case odin_tokenizer.Token_Kind.B_Keyword_Begin < kind && kind < odin_tokenizer.Token_Kind.B_Keyword_End:
		return .Keyword
	}
	return .Other
}

@(private = "file")
Expected_Token :: struct {
	kind:   odin_tokenizer.Token_Kind,
	offset: u32,
}

@(private = "file")
collect_odin_files :: proc(dir: string, paths: ^[dynamic]string) {
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for file_info in files {
		#partial switch file_info.type {
		case .Directory:
			collect_odin_files(file_info.fullpath, paths)
		case .Regular, .Symlink:
			if strings.has_suffix(file_info.name, ".odin") {
				append(paths, strings.clone(file_info.fullpath))
			}
		}
	}
}

// Compares token count and start offsets against `core:odin/tokenizer` over
// real files. Reference comments are dropped and `#`+identifier pairs merged.
@(test)
test_matches_core_tokenizer :: proc(test: ^testing.T) {
	defer free_all(context.temp_allocator)

	roots := []string{"/home/su3h7am/Projects/Odin/core/slice", "/home/su3h7am/Projects/Odin/core/strings"}
	files: [dynamic]string
	defer {
		for f in files {
			delete(f)
		}
		delete(files)
	}
	for root in roots {
		collect_odin_files(root, &files)
	}
	slice.sort(files[:])
	testing.expect(test, len(files) > 0, "no .odin files found to compare against")

	for path in files {
		src, read_error := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(test, read_error == nil, "could not read %s", path) {
			continue
		}

		actual: [dynamic]Token
		errors: [dynamic]Error
		scan_all(src, &actual, &errors)
		defer delete(actual)
		defer delete(errors)
		testing.expectf(test, len(errors) == 0, "%s: %d lexical errors %v", path, len(errors), errors)

		reference: odin_tokenizer.Tokenizer
		odin_tokenizer.init(&reference, string(src), path)
		reference.flags = {.Insert_Semicolon}
		reference_tokens: [dynamic]odin_tokenizer.Token
		for {
			reference_token := odin_tokenizer.scan(&reference)
			append(&reference_tokens, reference_token)
			if reference_token.kind == .EOF {
				break
			}
		}
		defer delete(reference_tokens)

		expected: [dynamic]Expected_Token
		i := 0
		for i < len(reference_tokens) {
			candidate := reference_tokens[i]
			if candidate.kind == .Comment {
				i += 1
			} else if candidate.kind == .File_Tag {
				append(&expected, Expected_Token{kind = .File_Tag, offset = u32(candidate.pos.offset)})
				i += 1
			} else if candidate.kind == .Hash &&
			   i + 1 < len(reference_tokens) &&
			   reference_tokens[i + 1].kind == .Ident &&
			   reference_tokens[i + 1].pos.offset == candidate.pos.offset + 1 {
				append(&expected, Expected_Token{kind = .File_Tag, offset = u32(candidate.pos.offset)})
				i += 2
			} else {
				append(&expected, Expected_Token{kind = candidate.kind, offset = u32(candidate.pos.offset)})
				i += 1
			}
		}
		defer delete(expected)

		mismatch := -1
		limit := min(len(actual), len(expected))
		for k in 0 ..< limit {
			if actual[k].start != expected[k].offset || class_actual(actual[k].kind) != class_reference(expected[k].kind) {
				mismatch = k
				break
			}
		}
		if mismatch >= 0 || len(actual) != len(expected) {
			testing.expectf(
				test,
				false,
				"%s: mismatch at token %d: mine=%v@%d core=%v@%d (counts %d vs %d)",
				path,
				mismatch,
				mismatch >= 0 ? actual[mismatch].kind : Token_Kind.Invalid,
				mismatch >= 0 ? actual[mismatch].start : u32(0),
				mismatch >= 0 ? expected[mismatch].kind : odin_tokenizer.Token_Kind.Invalid,
				mismatch >= 0 ? expected[mismatch].offset : u32(0),
				len(actual),
				len(expected),
			)
		}
	}
}

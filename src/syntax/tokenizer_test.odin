// Tests for the `syntax` tokenizer.
package syntax

import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import odin_tokenizer "core:odin/tokenizer"

// as_bytes returns a mutable view of `s` without copying. Only for tests.
@(private="file")
as_bytes :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

// scan_all drains a tokenizer over `source` into `tokens`, recording errors and
// comments when the corresponding sinks are non-nil.
@(private="file")
scan_all :: proc(source: []byte, tokens: ^[dynamic]Token, errors: ^[dynamic]Error = nil, comments: ^[dynamic]Comment = nil) {
	t := init(source, errors, comments)
	for {
		tok := next(&t)
		append(tokens, tok)
		if tok.kind == .EOF {
			break
		}
	}
}

@(private="file")
expect_kinds :: proc(t: ^testing.T, source: string, want: []Token_Kind) {
	errors: [dynamic]Error
	tokens: [dynamic]Token
	defer delete(errors)
	defer delete(tokens)

	scan_all(transmute([]byte)source, &tokens, &errors)
	testing.expectf(t, len(errors) == 0, "%q: unexpected errors %v", source, errors)
	testing.expectf(t, len(tokens) == len(want), "%q: got %d tokens, want %d", source, len(tokens), len(want))

	n := min(len(tokens), len(want))
	for i in 0 ..< n {
		if tokens[i].kind != want[i] {
			testing.expectf(t, false, "%q: token %d is %v, want %v", source, i, tokens[i].kind, want[i])
			return
		}
	}
}

@(test)
test_token_kinds :: proc(t: ^testing.T) {
	cases := []struct {
		source: string,
		kinds:  []Token_Kind,
	} {
		{"", {.EOF}},
		{"foo", {.Ident, .Semicolon, .EOF}},
		{"_x1", {.Ident, .Semicolon, .EOF}},
		{"return", {.Return, .Semicolon, .EOF}},
		{"fallthrough", {.Fallthrough, .Semicolon, .EOF}},
		{"not_in", {.Not_In, .EOF}},
		{"matrix", {.Matrix, .EOF}},
		{"123", {.Integer, .Semicolon, .EOF}},
		{"1_000_000", {.Integer, .Semicolon, .EOF}},
		{"0b1010", {.Integer, .Semicolon, .EOF}},
		{"0o17", {.Integer, .Semicolon, .EOF}},
		{"0d99", {.Integer, .Semicolon, .EOF}},
		{"0z1a", {.Integer, .Semicolon, .EOF}},
		{"0xff", {.Integer, .Semicolon, .EOF}},
		{"1.5", {.Float, .Semicolon, .EOF}},
		{"1e10", {.Float, .Semicolon, .EOF}},
		{"1.5e-3", {.Float, .Semicolon, .EOF}},
		{"0h7ff0000000000000", {.Float, .Semicolon, .EOF}},
		{"2i", {.Imag, .Semicolon, .EOF}},
		{"3.5j", {.Imag, .Semicolon, .EOF}},
		{"4k", {.Imag, .Semicolon, .EOF}},
		{"'a'", {.Rune, .Semicolon, .EOF}},
		{"'\\n'", {.Rune, .Semicolon, .EOF}},
		{"'\\u00e9'", {.Rune, .Semicolon, .EOF}},
		{"\"str\"", {.String, .Semicolon, .EOF}},
		{"\"\"\"multi\nline\"\"\"", {.String, .Semicolon, .EOF}},
		{"`raw`", {.Raw_String, .Semicolon, .EOF}},
		{"```triple```", {.Raw_String, .Semicolon, .EOF}},
		{"->", {.Arrow_Right, .EOF}},
		{"---", {.Undef, .Semicolon, .EOF}},
		{"..", {.Ellipsis, .EOF}},
		{"..<", {.Range_Half, .EOF}},
		{"..=", {.Range_Full, .EOF}},
		{"&~", {.And_Not, .EOF}},
		{"&~=", {.And_Not_Eq, .EOF}},
		{"&&=", {.Cmp_And_Eq, .EOF}},
		{"**", {.Mul_Mul, .EOF}},
		{"%%=", {.Mod_Mod_Eq, .EOF}},
		{"?", {.Question, .Semicolon, .EOF}},
		{"@", {.At, .EOF}},
		{"$", {.Dollar, .EOF}},
		{"^", {.Pointer, .Semicolon, .EOF}},
		{"#", {.Directive, .EOF}},
		{"#partial", {.Directive, .Semicolon, .EOF}},
		{"#+private", {.Directive, .EOF}},
		{"x := 1", {.Ident, .Colon, .Eq, .Integer, .Semicolon, .EOF}},
		{"a.b", {.Ident, .Period, .Ident, .Semicolon, .EOF}},
	}

	for tc in cases {
		expect_kinds(t, tc.source, tc.kinds)
	}
}

@(test)
test_token_spans :: proc(t: ^testing.T) {
	source := as_bytes("foo bar")
	tokens: [dynamic]Token
	defer delete(tokens)
	scan_all(source, &tokens)

	testing.expect_value(t, len(tokens), 4)
	testing.expect_value(t, token_text(source, tokens[0]), "foo")
	testing.expect_value(t, tokens[0].start, u32(0))
	testing.expect_value(t, tokens[0].end, u32(3))
	testing.expect_value(t, token_text(source, tokens[1]), "bar")
	testing.expect_value(t, tokens[1].start, u32(4))
	testing.expect_value(t, tokens[1].end, u32(7))
}

@(test)
test_semicolon_insertion :: proc(t: ^testing.T) {
	cases := []struct {
		source: string,
		kinds:  []Token_Kind,
	} {
		{"", {.EOF}},
		{"a", {.Ident, .Semicolon, .EOF}},
		{"a\n", {.Ident, .Semicolon, .EOF}},
		{"a\nb", {.Ident, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"a\n\nb", {.Ident, .Semicolon, .Ident, .Semicolon, .EOF}},
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
		// `+` does not trigger insertion, so the newline is plain whitespace.
		{"x +\ny", {.Ident, .Add, .Ident, .Semicolon, .EOF}},
		{"x // comment\ny", {.Ident, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x /* comment */\ny", {.Ident, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x;\ny", {.Ident, .Semicolon, .Ident, .Semicolon, .EOF}},
		{"x \\\ny", {.Ident, .Ident, .Semicolon, .EOF}},
	}

	for tc in cases {
		expect_kinds(t, tc.source, tc.kinds)
	}
}

@(test)
test_comments_recorded :: proc(t: ^testing.T) {
	source := as_bytes("a // one\n/* two */ b")
	tokens: [dynamic]Token
	comments: [dynamic]Comment
	errors: [dynamic]Error
	defer delete(tokens)
	defer delete(comments)
	defer delete(errors)
	scan_all(source, &tokens, &errors, &comments)

	testing.expect_value(t, len(errors), 0)
	testing.expect_value(t, len(comments), 2)
	if len(comments) == 2 {
		testing.expect_value(t, comments[0].kind, Comment_Kind.Line)
		testing.expect_value(t, comments[0].start, u32(2))
		testing.expect_value(t, comments[0].end, u32(8))
		testing.expect_value(t, comments[1].kind, Comment_Kind.Block)
		testing.expect_value(t, comments[1].start, u32(9))
		testing.expect_value(t, comments[1].end, u32(18))
	}
}

@(test)
test_nested_block_comment :: proc(t: ^testing.T) {
	expect_kinds(t, "/* a /* b */ c */x", {.Ident, .Semicolon, .EOF})
}

@(test)
test_errors :: proc(t: ^testing.T) {
	cases := []struct {
		source: string,
		kind:   Error_Kind,
	} {
		{"\"unterminated", .String_Not_Terminated},
		{"\"\"\"unterminated", .Triple_String_Not_Terminated},
		{"`unterminated", .Raw_String_Not_Terminated},
		{"'a", .Rune_Not_Terminated},
		{"'ab'", .Invalid_Rune_Literal},
		{"/* unterminated", .Comment_Not_Terminated},
		{"\"\\q\"", .Unknown_Escape_Sequence},
		{"\"\\uD800\"", .Invalid_Unicode_Code_Point},
		{"0b", .Invalid_Binary_Integer},
		{"0o", .Invalid_Octal_Integer},
		{"0d", .Invalid_Decimal_Integer},
		{"0z", .Invalid_Dozenal_Integer},
		{"0x", .Invalid_Hexadecimal_Integer},
		{"0hxyz", .Invalid_Hexadecimal_Float},
		{"1e", .Invalid_Float_Exponent},
		{"a\x00b", .Nul_Byte},
		{"\xff", .Illegal_Utf8},
	}

	for tc in cases {
		errors: [dynamic]Error
		tokens: [dynamic]Token
		scan_all(transmute([]byte)tc.source, &tokens, &errors)

		found := false
		for e in errors {
			if e.kind == tc.kind {
				found = true
			}
		}
		testing.expectf(t, found, "%q: expected error %v, got %v", tc.source, tc.kind, errors)
		delete(errors)
		delete(tokens)
	}
}

@(test)
test_error_offsets :: proc(t: ^testing.T) {
	source := as_bytes("a /* unterminated")
	errors: [dynamic]Error
	tokens: [dynamic]Token
	scan_all(source, &tokens, &errors)
	defer delete(errors)
	defer delete(tokens)

	testing.expect_value(t, len(errors), 1)
	if len(errors) == 1 {
		testing.expect_value(t, errors[0].kind, Error_Kind.Comment_Not_Terminated)
		testing.expect_value(t, errors[0].offset, u32(2))
	}
}

@(test)
test_leading_bom :: proc(t: ^testing.T) {
	expect_kinds(t, "\xEF\xBB\xBFident", {.Ident, .Semicolon, .EOF})
}

@(test)
test_line_col :: proc(t: ^testing.T) {
	source := as_bytes("ab\ncde\n")
	table, err := make_line_table(source, context.allocator)
	defer destroy_line_table(&table)
	testing.expect_value(t, err, mem.Allocator_Error.None)

	cases := []struct {
		offset: u32,
		line:   u32,
		column: u32,
	} {
		{0, 1, 1},
		{1, 1, 2},
		{3, 2, 1},
		{5, 2, 3},
		{6, 2, 4},
		{7, 3, 1},
	}
	for tc in cases {
		line, column := line_col(table, tc.offset)
		testing.expectf(t, line == tc.line && column == tc.column,
			"offset %d: got %d:%d, want %d:%d", tc.offset, line, column, tc.line, tc.column)
	}
}

// Broad token classes, used to compare against the reference tokenizer without
// depending on its exact kind numbering or its comment/file-tag representation.
@(private="file")
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

@(private="file")
class_mine :: proc(kind: Token_Kind) -> Class {
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

@(private="file")
class_core :: proc(kind: odin_tokenizer.Token_Kind) -> Class {
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

@(private="file")
Core_Norm :: struct {
	kind:   odin_tokenizer.Token_Kind,
	offset: u32,
}

@(private="file")
collect_odin_files :: proc(dir: string, out: ^[dynamic]string) {
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in files {
		#partial switch fi.type {
		case .Directory:
			collect_odin_files(fi.fullpath, out)
		case .Regular, .Symlink:
			if strings.has_suffix(fi.name, ".odin") {
				append(out, strings.clone(fi.fullpath))
			}
		}
	}
}

// test_matches_core_tokenizer scans every `.odin` file under the reference
// `core/slice` and `core/strings` directories and checks that this tokenizer
// agrees with `core:odin/tokenizer` on token count and start offsets.
//
// Comments are dropped from the reference stream and `#name` directives (which
// the reference splits into `#` plus an identifier) are merged, so the two
// streams line up one to one. Kinds are compared by broad class.
@(test)
test_matches_core_tokenizer :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	roots := []string {
		"/home/su3h7am/Projects/Odin/core/slice",
		"/home/su3h7am/Projects/Odin/core/strings",
	}
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
	testing.expect(t, len(files) > 0, "no .odin files found to compare against")

	for path in files {
		src, read_err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, read_err == nil, "could not read %s", path) {
			continue
		}

		// This tokenizer.
		mine: [dynamic]Token
		errors: [dynamic]Error
		scan_all(src, &mine, &errors)
		defer delete(mine)
		defer delete(errors)
		testing.expectf(t, len(errors) == 0, "%s: %d lexical errors %v", path, len(errors), errors)

		// The reference tokenizer, with semicolon insertion enabled.
		ct: odin_tokenizer.Tokenizer
		odin_tokenizer.init(&ct, string(src), path)
		ct.flags = {.Insert_Semicolon}
		core_tokens: [dynamic]odin_tokenizer.Token
		for {
			tok := odin_tokenizer.scan(&ct)
			append(&core_tokens, tok)
			if tok.kind == .EOF {
				break
			}
		}
		defer delete(core_tokens)

		norm: [dynamic]Core_Norm
		i := 0
		for i < len(core_tokens) {
			tk := core_tokens[i]
			if tk.kind == .Comment {
				i += 1
			} else if tk.kind == .File_Tag {
				append(&norm, Core_Norm{kind = .File_Tag, offset = u32(tk.pos.offset)})
				i += 1
			} else if tk.kind == .Hash &&
			          i + 1 < len(core_tokens) &&
			          core_tokens[i + 1].kind == .Ident &&
			          core_tokens[i + 1].pos.offset == tk.pos.offset + 1 {
				append(&norm, Core_Norm{kind = .File_Tag, offset = u32(tk.pos.offset)})
				i += 2
			} else {
				append(&norm, Core_Norm{kind = tk.kind, offset = u32(tk.pos.offset)})
				i += 1
			}
		}
		defer delete(norm)

		mismatch := -1
		n := min(len(mine), len(norm))
		for k in 0 ..< n {
			if mine[k].start != norm[k].offset ||
			   class_mine(mine[k].kind) != class_core(norm[k].kind) {
				mismatch = k
				break
			}
		}
		if mismatch >= 0 || len(mine) != len(norm) {
			testing.expectf(t, false,
				"%s: mismatch at token %d: mine=%v@%d core=%v@%d (counts %d vs %d)",
				path, mismatch,
				mismatch >= 0 ? mine[mismatch].kind : Token_Kind.Invalid,
				mismatch >= 0 ? mine[mismatch].start : u32(0),
				mismatch >= 0 ? norm[mismatch].kind : odin_tokenizer.Token_Kind.Invalid,
				mismatch >= 0 ? norm[mismatch].offset : u32(0),
				len(mine), len(norm))
		}
	}
}

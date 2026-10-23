package syntax

import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:testing"

@(test)
undefined_body_belongs_to_outer_proc_after_proc_type_result :: proc(t: ^testing.T) {
	source := transmute([]byte)string(`package sample
signal :: proc(sig: int, func: proc "c" (int)) -> proc "c" (int) ---
`)
	ast: Ast
	ast_init(&ast, context.allocator)
	defer ast_destroy(&ast)
	parser: Parser
	parser_init(&parser, &ast, source)
	defer parser_destroy(&parser)
	parse_file(&parser)
	testing.expect(t, len(parser.errors) == 0)
	literals, types: int
	for node in ast.nodes {
		#partial switch node.kind {
		case .Proc_Lit:
			literals += 1
		case .Proc_Type:
			types += 1
		}
	}
	testing.expect_value(t, literals, 1)
	testing.expect_value(t, types, 3)
}

parse_expression_for_test :: proc(p: ^Parser, ast: ^Ast, source: string) -> Node_Index {

	parser_init(p, ast, transmute([]byte)source)
	root := parse_expr(p, false)
	if is_inserted_semicolon(p.curr) {
		advance_token(p)
	}
	return root
}

// parse_body_for_test parses `source` as a procedure body, so statements are checked in proc context.
parse_body_for_test :: proc(p: ^Parser, ast: ^Ast, source: string) -> Node_Index {
	parser_init(p, ast, transmute([]byte)source)
	p.proc_depth = 1
	return parse_body(p)
}

collect_child_indices :: proc(ast: ^Ast, index: Node_Index, children: ^[dynamic]Node_Index) {
	node := &ast.nodes[index]
	variant := reflect.get_union_variant(any{rawptr(&node.payload), typeid_of(Node_Payload)})
	if variant.id == nil {
		return
	}
	for field in reflect.struct_fields_zipped(variant.id) {
		location := rawptr(uintptr(variant.data) + field.offset)
		if field.type.id == typeid_of(Node_Index) {
			child := (^Node_Index)(location)^
			if child != 0 {
				append(children, child)
			}
		} else if field.type.id == typeid_of(Node_Range) {
			for child in node_list(ast, (^Node_Range)(location)^) {
				append(children, child)
			}
		}
	}
}

expect_spans_nested :: proc(t: ^testing.T, ast: ^Ast, source_length: int, file_path: string) {
	children: [dynamic]Node_Index
	defer delete(children)
	for index in 1 ..< len(ast.nodes) {
		node := ast.nodes[index]
		testing.expectf(
			t,
			node.start <= node.end && int(node.end) <= source_length,
			"%s: node %d %v span %d..%d outside source of %d bytes",
			file_path,
			index,
			node.kind,
			node.start,
			node.end,
			source_length,
		)
		clear(&children)
		collect_child_indices(ast, Node_Index(index), &children)
		for child in children {
			child_node := ast.nodes[child]
			testing.expectf(
				t,
				child_node.start >= node.start && child_node.end <= node.end,
				"%s: %v %d..%d does not contain child %v %d..%d",
				file_path,
				node.kind,
				node.start,
				node.end,
				child_node.kind,
				child_node.start,
				child_node.end,
			)
		}
	}
}

@(test)
test_parse_corpus_without_errors :: proc(t: ^testing.T) {
	directories := [?]string{"core/strings", "core/slice", "core/fmt", "core/os", "core/mem", "base/runtime"}
	for directory in directories {
		root, _ := filepath.join({#directory, "..", "..", directory}, context.temp_allocator)
		walker := os.walker_create(root)
		defer os.walker_destroy(&walker)
		for info in os.walker_walk(&walker) {
			if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
				continue
			}
			source, read_err := os.read_entire_file_from_path(info.fullpath, context.allocator)
			defer delete(source)
			testing.expectf(t, read_err == nil, "%s: read failed: %v", info.fullpath, read_err)

			ast: Ast
			ast_init(&ast)
			defer ast_destroy(&ast)
			p: Parser
			defer parser_destroy(&p)
			parser_init(&p, &ast, source)
			parse_file(&p)
			testing.expectf(t, len(p.errors) == 0 && len(p.lex_errors) == 0, "%s: parse errors %v, lexical errors %v", info.fullpath, p.errors, p.lex_errors)
			expect_spans_nested(t, &ast, len(source), info.fullpath)
		}
	}
}

@(test)
test_ast_dump_statements_and_expressions :: proc(t: ^testing.T) {
	expression_sources := [?]string {
		"([^]byte)(raw_data(slice))[:size]",
		"make([]byte, len(s), allocator, loc=loc) or_return",
		"_reader_read_new_chunk(b) or_return",
		"buffer_write(b, ([^]byte)(ptr)[:size], loc=loc)",
		"([^]byte)(data)[:len]",
		"transmute([]byte)string(val)",
		"transmute(f16)n",
		"endian.unchecked_put_u16be(bytes[1:], transmute(u16)v)",
		"string(a.key^)",
		"tag.?",
		"Decoder_Flags{}",
		"Header(0)",
		"#caller_location",
		"context.allocator",
		"bit_set[Encoder_Flag]",
		"map[Tag_Number]Tag_Implementation",
		"map[typeid]Tag_Implementation",
		"[^]char",
		"^[^]char",
		"proc \"c\" (int)",
		"proc \"c\" (lhs, rhs: rawptr) -> int",
		"proc(key, base: rawptr, nmemb, size: size_t, compar: proc \"c\" (lhs, rhs: rawptr) -> int) -> rawptr",
		"proc(s: [^]char, n: size_t, format: cstring, #c_vararg args: ..any) -> int",
		"proc(sig: int, func: proc \"c\" (int)) -> proc \"c\" (int)",
		"proc(stream: ^FILE, buf: [^]char, mode: int, size: size_t) -> int",
		"proc(s: cstring, c: int) -> [^]char",
		"proc(v: $T, err: Decode_Error) -> (T, Unmarshal_Error)",
		"proc(s: string, flags: Decoder_Flags = {}, allocator := context.allocator) -> (v: Value, err: Decode_Error)",
		"proc(stream: ^FILE, format: cstring, arg: ^va_list) -> int",
		"asm(a: i8) -> (r: i16) { movsx r, a; }",
		"#force_inline(gt(y, x)) ~ 1",
		"proc(v: Foo(..))",
	}
	for source in expression_sources {
		ast: Ast
		ast_init(&ast)
		p: Parser
		parse_expression_for_test(&p, &ast, source)
		testing.expectf(
			t,
			len(p.errors) == 0 && len(p.lex_errors) == 0 && p.curr.kind == .EOF,
			"%q: parse errors %v, lexical errors %v",
			source,
			p.errors,
			p.lex_errors,
		)
		parser_destroy(&p)
		ast_destroy(&ast)
	}

	expression_dump_cases := [?]struct {
		source:   string,
		expected: string,
	} {
		{
			"make([]byte, len(s), allocator, loc=loc) or_return",
			`Or_Return_Expr 0..50 token=Or_Return
  expr: Call_Expr 0..40 "make([]byte, len(s), allocator, loc=loc)" inlining=None tailing=None open=4 ellipsis=Invalid close=39
    expr: Ident 0..4 "make"
    args[0]: Array_Type 5..11 "[]byte" open=5 close=6
      elem: Ident 7..11 "byte"
    args[1]: Call_Expr 13..19 "len(s)" inlining=None tailing=None open=16 ellipsis=Invalid close=18
      expr: Ident 13..16 "len"
      args[0]: Ident 17..18 "s"
    args[2]: Ident 21..30 "allocator"
    args[3]: Field_Value 32..39 "loc=loc" sep=35
      field: Ident 32..35 "loc"
      value: Ident 36..39 "loc"
`,
		},
	}
	for dump_case in expression_dump_cases {
		ast: Ast
		ast_init(&ast)
		p: Parser
		ast.root = parse_expression_for_test(&p, &ast, dump_case.source)

		dump: strings.Builder
		ast_dump(&ast, p.tokenizer.source, &dump)
		testing.expect_value(t, strings.to_string(dump), dump_case.expected)

		strings.builder_destroy(&dump)
		parser_destroy(&p)
		ast_destroy(&ast)
	}

	statement_source := `{
	x := 1
	if x > 0 { x += 1 } else { x -= 1 }
	for i in 0 ..< 3 { defer continue }
	return
}`
	ast: Ast
	ast_init(&ast)
	p: Parser
	ast.root = parse_body_for_test(&p, &ast, statement_source)
	testing.expectf(t, len(p.errors) == 0 && len(p.lex_errors) == 0, "parse errors %v", p.errors)

	dump: strings.Builder
	ast_dump(&ast, p.tokenizer.source, &dump)
	testing.expect_value(
		t,
		strings.to_string(dump),
		`Block_Stmt 0..93 open=0 close=92 uses_do=false
  stmts[0]: Value_Decl 3..9 "x := 1" is_using=false is_mutable=true
    names[0]: Ident 3..4 "x"
    values[0]: Basic_Lit 8..9 "1" kind=Integer
  stmts[1]: If_Stmt 11..46 "if x > 0 { x += 1 } else { x -= 1 }" if_pos=11 else_pos=31
    cond: Binary_Expr 14..19 "x > 0" op=Gt
      left: Ident 14..15 "x"
      right: Basic_Lit 18..19 "0" kind=Integer
    body: Block_Stmt 20..30 "{ x += 1 }" open=20 close=29 uses_do=false
      stmts[0]: Assign_Stmt 22..28 "x += 1" op=Add_Eq
        lhs[0]: Ident 22..23 "x"
        rhs[0]: Basic_Lit 27..28 "1" kind=Integer
    else_stmt: Block_Stmt 36..46 "{ x -= 1 }" open=36 close=45 uses_do=false
      stmts[0]: Assign_Stmt 38..44 "x -= 1" op=Sub_Eq
        lhs[0]: Ident 38..39 "x"
        rhs[0]: Basic_Lit 43..44 "1" kind=Integer
  stmts[2]: Range_Stmt 48..83 "for i in 0 ..< 3 { defer continue }" for_pos=48 in_pos=54 reverse=false
    vals[0]: Ident 52..53 "i"
    expr: Binary_Expr 57..64 "0 ..< 3" op=Range_Half
      left: Basic_Lit 57..58 "0" kind=Integer
      right: Basic_Lit 63..64 "3" kind=Integer
    body: Block_Stmt 65..83 "{ defer continue }" open=65 close=82 uses_do=false
      stmts[0]: Defer_Stmt 67..81 "defer continue"
        stmt: Branch_Stmt 73..81 "continue" token=Continue
  stmts[3]: Return_Stmt 85..91 "return"
`,
	)

	strings.builder_destroy(&dump)
	parser_destroy(&p)
	ast_destroy(&ast)
}

@(test)
test_parse_errors_recover :: proc(t: ^testing.T) {
	expression_cases := [?]struct {
		source:      string,
		first_error: Parse_Error_Kind,
	}{{"f(a b)", .Expected_Token}, {"a +", .Expected_Operand}, {"a->", .Expected_Selector}, {"proc(", .Expected_Token}}
	for test_case in expression_cases {
		ast: Ast
		ast_init(&ast)
		p: Parser
		parse_expression_for_test(&p, &ast, test_case.source)
		testing.expectf(t, len(p.errors) > 0 && p.errors[0].kind == test_case.first_error, "%q: parse errors %v", test_case.source, p.errors)
		parser_destroy(&p)
		ast_destroy(&ast)
	}

	statement_cases := [?]struct {
		source:      string,
		first_error: Parse_Error_Kind,
	}{{"{ x := 1 2 }", .Expected_Token}, {"{ x = }", .Expected_Operand}, {"{ import \"core:fmt\" }", .Misplaced_Statement}}
	for test_case in statement_cases {
		ast: Ast
		ast_init(&ast)
		p: Parser
		parse_body_for_test(&p, &ast, test_case.source)
		testing.expectf(t, len(p.errors) > 0 && p.errors[0].kind == test_case.first_error, "%q: parse errors %v", test_case.source, p.errors)
		parser_destroy(&p)
		ast_destroy(&ast)
	}
}
@(test)
matrix_order_directive_tags_matrix_type_only :: proc(t: ^testing.T) {
	cases := [?]struct {
		source:    string,
		errors:    int,
		is_matrix: bool,
		is_tagged: bool,
	} {
		{"#row_major matrix[2,3]f32", 0, true, true},
		{"#column_major matrix[2,3]f32", 0, true, true},
		{"matrix[2,3]f32", 0, true, false},
		{"#row_major [2]f32", 1, false, false},
	}
	for test_case in cases {
		ast: Ast
		ast_init(&ast, context.allocator)
		defer ast_destroy(&ast)
		parser: Parser
		root := parse_expression_for_test(&parser, &ast, test_case.source)
		defer parser_destroy(&parser)
		testing.expectf(t, len(parser.errors) == test_case.errors, "%q: errors %d", test_case.source, len(parser.errors))
		is_matrix := ast.nodes[root].kind == .Matrix_Type
		testing.expectf(t, is_matrix == test_case.is_matrix, "%q: matrix %v", test_case.source, is_matrix)
		if is_matrix {
			tagged := node_payload(&ast, root, Matrix_Type).tag != 0
			testing.expectf(t, tagged == test_case.is_tagged, "%q: tagged %v", test_case.source, tagged)
		}
	}
}

@(test)
vet_semicolon_rejects_only_unneeded_explicit_semicolons :: proc(t: ^testing.T) {
	for row in ([]struct {
			source: string,
			errors: int,
		}{{"package sample\nf :: proc() { x := 1; _ = x }\n", 0}, {"package sample\nf :: proc() { x := 1;\n_ = x }\n", 1}, {"package sample\nf :: proc() { for i := 0; i < 2; i += 1 {} }\n", 0}}) {
		ast: Ast
		ast_init(&ast, context.allocator)
		defer ast_destroy(&ast)
		parser: Parser
		parser_init(&parser, &ast, transmute([]byte)row.source)
		defer parser_destroy(&parser)
		parser.options.vet = {.Semicolon}
		parse_file(&parser)
		testing.expect_value(t, len(parser.errors), row.errors)
		if len(parser.errors) != 0 { testing.expect_value(t, parser.errors[0].kind, Parse_Error_Kind.Unneeded_Semicolon) }
	}
}

package syntax

Stmt_Allow_Flag :: enum u8 {
	Label,
	In,
}

Stmt_Allow_Flags :: distinct bit_set[Stmt_Allow_Flag;u8]

is_assignment_operator :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Eq, .Add_Eq, .Sub_Eq, .Mul_Eq, .Quo_Eq, .Mod_Eq, .Mod_Mod_Eq, .And_Eq, .Or_Eq, .Xor_Eq, .And_Not_Eq, .Shl_Eq, .Shr_Eq, .Cmp_And_Eq, .Cmp_Or_Eq:
		return true
	}
	return false
}

// range_span returns the start of the first node and the end of the last node in a non-empty range.
range_span :: proc(p: ^Parser, range: Node_Range) -> (start, end: u32) {
	nodes := node_list(p.ast, range)
	start, _ = node_span(p.ast, nodes[0])
	_, end = node_span(p.ast, nodes[len(nodes) - 1])
	return
}

is_semicolon_optional_for_node :: proc(p: ^Parser, node: Node_Index) -> bool {
	if node == 0 {
		return false
	}
	#partial switch p.ast.nodes[node].kind {
	case .Empty_Stmt,
	     .Block_Stmt,
	     .If_Stmt,
	     .When_Stmt,
	     .For_Stmt,
	     .Range_Stmt,
	     .Unroll_Range_Stmt,
	     .Switch_Stmt,
	     .Type_Switch_Stmt,
	     .Proc_Lit,
	     .Package_Decl,
	     .Import_Decl,
	     .Foreign_Import_Decl:
		return true
	case .Helper_Type:
		return is_semicolon_optional_for_node(p, node_payload(p.ast, node, Helper_Type).type)
	case .Distinct_Type:
		return is_semicolon_optional_for_node(p, node_payload(p.ast, node, Distinct_Type).type)
	case .Pointer_Type:
		return is_semicolon_optional_for_node(p, node_payload(p.ast, node, Pointer_Type).elem)
	case .Struct_Type, .Union_Type, .Enum_Type, .Bit_Set_Type, .Bit_Field_Type:
		return p.proc_depth == 0
	case .Foreign_Block_Decl:
		return is_semicolon_optional_for_node(p, node_payload(p.ast, node, Foreign_Block_Decl).body)
	case .Value_Decl:
		payload := node_payload(p.ast, node, Value_Decl)
		if payload.is_mutable {
			return false
		}
		values := node_list(p.ast, payload.values)
		if len(values) > 0 {
			return is_semicolon_optional_for_node(p, values[len(values) - 1])
		}
	}
	return false
}

fix_advance_to_next_stmt :: proc(p: ^Parser) {
	for {
		#partial switch p.curr.kind {
		case .EOF, .Semicolon:
			return
		case .Package, .Foreign, .Import, .If, .For, .When, .Return, .Switch, .Defer, .Using, .Break, .Continue, .Fallthrough, .Directive:
			return
		}
		advance_token(p)
	}
}

// expect_semicolon reports a missing `;` unless the position allows it. Every caller has consumed
// at least one token, so the statement loops always make progress.
expect_semicolon :: proc(p: ^Parser, node: Node_Index) -> bool {
	check_unneeded_semicolon(p)
	if allow_token(p, .Semicolon) {
		return true
	}
	if p.prev.kind == .Semicolon || p.curr.kind == .EOF {
		return true
	}
	if newline_between(p, p.prev.end, p.curr.start) {
		return true
	}
	#partial switch p.curr.kind {
	case .Close_Brace, .Close_Paren, .Else:
		return true
	}
	if is_semicolon_optional_for_node(p, node) {
		return true
	}
	report(p, .Expected_Token, p.prev.end, .Semicolon)
	fix_advance_to_next_stmt(p)
	return false
}

parse_stmt_list :: proc(p: ^Parser) -> Node_Range {
	stmts := make([dynamic]Node_Index, 0, 8, p.allocator)
	defer delete(stmts)
	for p.curr.kind != .Case && p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
		enforce_tab_indentation(p)
		stmt := parse_stmt(p)
		if p.ast.nodes[stmt].kind == .Empty_Stmt {
			continue
		}
		push(p, &stmts, stmt)
		if p.ast.nodes[stmt].kind == .Expr_Stmt {
			expr := node_payload(p.ast, stmt, Expr_Stmt).expr
			if p.ast.nodes[expr].kind == .Proc_Lit {
				report(p, .Misplaced_Statement, p.ast.nodes[stmt].start)
			}
		}
	}
	return ast_add_list(p.ast, stmts[:])
}

parse_block_stmt :: proc(p: ^Parser, is_when: bool) -> Node_Index {
	skip_possible_newline_before_brace(p)
	if !is_when && p.proc_depth == 0 {
		report(p, .File_Scope_Statement, p.curr.start)
	}
	return parse_body(p)
}

// parse_do_body parses the statement after `do`, which must start on the line of the header.
parse_do_body :: proc(p: ^Parser, header_end: u32) -> Node_Index {
	body := convert_stmt_to_body(p, parse_stmt(p))
	if p.options.disallow_do {
		report(p, .Disallowed_Do, p.ast.nodes[body].start)
	} else if newline_between(p, header_end, p.ast.nodes[body].start) {
		report(p, .Misplaced_Do_Body, p.ast.nodes[body].start)
	}
	return body
}

parse_control_body :: proc(p: ^Parser, header_end: u32, is_when: bool) -> Node_Index {
	if allow_token(p, .Do) {
		return parse_do_body(p, header_end)
	}
	return parse_block_stmt(p, is_when)
}

parse_loop_body :: proc(p: ^Parser, header_end: u32) -> Node_Index {
	if allow_token(p, .Do) {
		return parse_do_body(p, header_end)
	}
	skip_possible_newline(p)
	return parse_body(p)
}

convert_stmt_to_body :: proc(p: ^Parser, stmt: Node_Index) -> Node_Index {
	start, end := node_span(p.ast, stmt)
	#partial switch p.ast.nodes[stmt].kind {
	case .Block_Stmt:
		report(p, .Misplaced_Statement, start)
		return stmt
	case .Empty_Stmt:
		report(p, .Misplaced_Statement, start)
	}
	stmts := ast_add_list(p.ast, []Node_Index{stmt})
	return add_node(p, .Block_Stmt, start, end, Block_Stmt{open = start, stmts = stmts, close = end, uses_do = true})
}

convert_stmt_to_expr :: proc(p: ^Parser, stmt: Node_Index) -> Node_Index {
	if stmt == 0 {
		return 0
	}
	if p.ast.nodes[stmt].kind == .Expr_Stmt {
		return node_payload(p.ast, stmt, Expr_Stmt).expr
	}
	start, end := node_span(p.ast, stmt)
	report(p, .Expected_Operand, start)
	return add_node(p, .Bad_Expr, start, end, Bad_Expr{})
}

parse_control_statement_semicolon_separator :: proc(p: ^Parser) -> bool {
	if is_non_inserted_semicolon(p.curr) {
		advance_token(p)
		return true
	}
	return false
}

parse_when_stmt :: proc(p: ^Parser) -> Node_Index {
	when_tok := expect_token(p, .When)

	prev_level := p.expr_level
	p.expr_level = -1
	prev_allow_in_expr := p.allow_in_expr
	p.allow_in_expr = true
	cond := parse_expr(p, false)
	p.allow_in_expr = prev_allow_in_expr
	p.expr_level = prev_level

	body := parse_control_body(p, p.prev.end, true)

	skip_possible_newline_before_brace(p, !newline_between(p, when_tok.start, p.ast.nodes[body].end))
	else_stmt: Node_Index
	if p.curr.kind == .Else {
		else_tok := expect_token(p, .Else)
		#partial switch p.curr.kind {
		case .When:
			else_stmt = parse_when_stmt(p)
		case .Open_Brace:
			else_stmt = parse_block_stmt(p, true)
		case .Do:
			expect_token(p, .Do)
			else_stmt = parse_do_body(p, else_tok.end)
		case:
			report(p, .Expected_Statement, p.curr.start)
			else_stmt = add_node(p, .Bad_Stmt, p.curr.start, p.curr.end, Bad_Stmt{})
		}
	}

	return add_node(p, .When_Stmt, when_tok.start, p.prev.end, When_Stmt{when_pos = when_tok.start, cond = cond, body = body, else_stmt = else_stmt})
}

parse_if_stmt :: proc(p: ^Parser) -> Node_Index {
	if_tok := expect_token(p, .If)

	init, cond: Node_Index
	prev_level := p.expr_level
	p.expr_level = -1
	prev_allow_in_expr := p.allow_in_expr
	p.allow_in_expr = true
	if is_decl_on_later_line(p) {
		report(p, .Expected_Operand, if_tok.end)
		cond = add_node(p, .Bad_Expr, if_tok.end, if_tok.end, Bad_Expr{})
	} else if is_non_inserted_semicolon(p.curr) {
		advance_token(p)
		cond = parse_expr(p, false)
	} else {
		init = parse_simple_stmt(p, {})
		if parse_control_statement_semicolon_separator(p) {
			cond = parse_expr(p, false)
		} else {
			cond = convert_stmt_to_expr(p, init)
			init = 0
		}
	}
	p.allow_in_expr = prev_allow_in_expr
	p.expr_level = prev_level

	body := parse_control_body(p, p.prev.end, false)

	else_pos: u32
	else_stmt: Node_Index
	skip_possible_newline_before_brace(p, !newline_between(p, if_tok.start, p.ast.nodes[body].end))
	if p.curr.kind == .Else {
		else_tok := expect_token(p, .Else)
		else_pos = else_tok.start
		#partial switch p.curr.kind {
		case .If:
			else_stmt = parse_if_stmt(p)
		case .Open_Brace:
			else_stmt = parse_block_stmt(p, false)
		case .Do:
			expect_token(p, .Do)
			else_stmt = parse_do_body(p, else_tok.end)
		case:
			report(p, .Expected_Statement, p.curr.start)
			else_stmt = add_node(p, .Bad_Stmt, p.curr.start, p.curr.end, Bad_Stmt{})
		}
	}

	return add_node(
		p,
		.If_Stmt,
		if_tok.start,
		p.prev.end,
		If_Stmt{if_pos = if_tok.start, init = init, cond = cond, body = body, else_pos = else_pos, else_stmt = else_stmt},
	)
}

is_in_assignment :: proc(p: ^Parser, stmt: Node_Index) -> bool {
	return stmt != 0 && p.ast.nodes[stmt].kind == .Assign_Stmt && node_payload(p.ast, stmt, Assign_Stmt).op.kind == .In
}

parse_for_stmt :: proc(p: ^Parser) -> Node_Index {
	if p.proc_depth == 0 {
		report(p, .File_Scope_Statement, p.curr.start)
	}
	for_tok := expect_token(p, .For)

	init, cond_stmt, post: Node_Index
	is_range := false
	if p.curr.kind != .Open_Brace && p.curr.kind != .Do && !is_decl_on_later_line(p) {
		prev_level := p.expr_level
		p.expr_level = -1
		if p.curr.kind == .In {
			in_tok := expect_token(p, .In)
			prev_allow_range := p.allow_range
			p.allow_range = true
			expr := parse_expr(p, false)
			p.allow_range = prev_allow_range
			p.expr_level = prev_level
			body := parse_loop_body(p, for_tok.end)
			return add_node(p, .Range_Stmt, for_tok.start, p.prev.end, Range_Stmt{for_pos = for_tok.start, in_pos = in_tok.start, expr = expr, body = body})
		}

		if p.curr.kind != .Semicolon {
			cond_stmt = parse_simple_stmt(p, {.In})
			is_range = is_in_assignment(p, cond_stmt)
		}
		if !is_range && parse_control_statement_semicolon_separator(p) {
			init = cond_stmt
			cond_stmt = 0
			if p.curr.kind == .Open_Brace || p.curr.kind == .Do {
				report(p, .Expected_Token, p.curr.start, .Semicolon)
			} else {
				if p.curr.kind != .Semicolon {
					next := peek_token(p, 0).kind
					if p.curr.kind == .Ident && (next == .In || next == .Comma) {
						cond_stmt = parse_simple_stmt(p, {.In})
						is_range = is_in_assignment(p, cond_stmt)
					} else {
						cond_stmt = parse_simple_stmt(p, {})
					}
				}
				if !is_range {
					if !allow_token(p, .Semicolon) {
						report(p, .Expected_Token, p.curr.start, .Semicolon)
					} else if p.curr.kind != .Open_Brace && p.curr.kind != .Do {
						post = parse_simple_stmt(p, {})
					}
				}
			}
		}
		p.expr_level = prev_level
	}

	body := parse_loop_body(p, for_tok.end)
	if is_range {
		assign := node_payload(p.ast, cond_stmt, Assign_Stmt)
		return add_node(
			p,
			.Range_Stmt,
			for_tok.start,
			p.prev.end,
			Range_Stmt{init = init, for_pos = for_tok.start, vals = assign.lhs, in_pos = assign.op.start, expr = node_list(p.ast, assign.rhs)[0], body = body},
		)
	}
	return add_node(
		p,
		.For_Stmt,
		for_tok.start,
		p.prev.end,
		For_Stmt{for_pos = for_tok.start, init = init, cond = convert_stmt_to_expr(p, cond_stmt), post = post, body = body},
	)
}

parse_case_clause :: proc(p: ^Parser, is_type_switch: bool) -> Node_Index {
	case_tok := expect_token(p, .Case)

	list: Node_Range
	if p.curr.kind != .Colon {
		prev_allow_range, prev_allow_in_expr := p.allow_range, p.allow_in_expr
		p.allow_range, p.allow_in_expr = !is_type_switch, !is_type_switch
		list = parse_expr_list(p, false)
		p.allow_range, p.allow_in_expr = prev_allow_range, prev_allow_in_expr
	}

	terminator := p.curr
	if !allow_token(p, .Colon) {
		report(p, .Expected_Token, p.curr.start, .Colon)
	}
	body := parse_stmt_list(p)

	return add_node(p, .Case_Clause, case_tok.start, p.prev.end, Case_Clause{case_pos = case_tok.start, list = list, terminator = terminator, body = body})
}

parse_switch_stmt :: proc(p: ^Parser) -> Node_Index {
	switch_tok := expect_token(p, .Switch)

	init, tag: Node_Index
	is_type_switch := false
	if p.curr.kind != .Open_Brace && p.curr.kind != .Case && !is_decl_on_later_line(p) {
		prev_level := p.expr_level
		p.expr_level = -1
		if p.curr.kind == .In {
			in_tok := expect_token(p, .In)
			is_type_switch = true
			blank := add_node(p, .Ident, in_tok.start, in_tok.start, Ident{})
			subject := parse_expr(p, true)
			tag = add_node(
				p,
				.Assign_Stmt,
				in_tok.start,
				p.prev.end,
				Assign_Stmt{lhs = ast_add_list(p.ast, []Node_Index{blank}), op = in_tok, rhs = ast_add_list(p.ast, []Node_Index{subject})},
			)
		} else {
			tag = parse_simple_stmt(p, {.In})
			if is_in_assignment(p, tag) {
				is_type_switch = true
			} else if parse_control_statement_semicolon_separator(p) {
				init = tag
				tag = 0
				if p.curr.kind != .Open_Brace {
					tag = parse_simple_stmt(p, {})
				}
			}
		}
		p.expr_level = prev_level
	}

	if is_inserted_semicolon(p.curr) && (peek_token(p, 0).kind == .Open_Brace || peek_token(p, 0).kind == .Case) {
		advance_token(p)
	}

	body: Node_Index
	if p.curr.kind == .Open_Brace || p.curr.kind == .Case {
		open := p.curr
		if !allow_token(p, .Open_Brace) {
			report(p, .Expected_Token, p.curr.start, .Open_Brace)
		}
		clauses := make([dynamic]Node_Index, 0, 4, p.allocator)
		defer delete(clauses)
		for p.curr.kind == .Case {
			push(p, &clauses, parse_case_clause(p, is_type_switch))
		}
		close := expect_token(p, .Close_Brace)
		body = add_node(p, .Block_Stmt, open.start, close.end, Block_Stmt{open = open.start, stmts = ast_add_list(p.ast, clauses[:]), close = close.start})
	} else {
		report(p, .Expected_Token, p.curr.start, .Open_Brace)
		body = add_node(p, .Block_Stmt, p.curr.start, p.curr.start, Block_Stmt{open = p.curr.start, close = p.curr.start})
	}

	if is_type_switch {
		subject := node_list(p.ast, node_payload(p.ast, tag, Assign_Stmt).rhs)[0]
		return add_node(
			p,
			.Type_Switch_Stmt,
			switch_tok.start,
			p.prev.end,
			Type_Switch_Stmt{switch_pos = switch_tok.start, tag = tag, expr = subject, body = body},
		)
	}
	return add_node(
		p,
		.Switch_Stmt,
		switch_tok.start,
		p.prev.end,
		Switch_Stmt{switch_pos = switch_tok.start, init = init, cond = convert_stmt_to_expr(p, tag), body = body},
	)
}

parse_unrolled_for_loop :: proc(p: ^Parser, tag: Token) -> Node_Index {
	args := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(args)
	if allow_token(p, .Open_Paren) {
		p.expr_level += 1
		if p.curr.kind == .Close_Paren {
			report(p, .Invalid_Unroll_Loop, p.curr.start)
		} else {
			for p.curr.kind != .Close_Paren && p.curr.kind != .EOF {
				arg := parse_value(p)
				if p.curr.kind == .Eq {
					eq := expect_token(p, .Eq)
					if p.ast.nodes[arg].kind != .Ident {
						report(p, .Invalid_Unroll_Loop, p.ast.nodes[arg].start)
					}
					value := parse_value(p)
					arg = add_node(p, .Field_Value, p.ast.nodes[arg].start, p.prev.end, Field_Value{field = arg, sep = eq.start, value = value})
				}
				push(p, &args, arg)
				if !allow_token(p, .Comma) {
					break
				}
			}
		}
		p.expr_level -= 1
		expect_closing(p, .Close_Paren)
	}

	for_tok := expect_token(p, .For)

	val0, val1: Node_Index
	bad_stmt := false
	if p.curr.kind != .In {
		idents := node_list(p.ast, parse_ident_list(p, false))
		switch len(idents) {
		case 1:
			val0 = idents[0]
		case 2:
			val0, val1 = idents[0], idents[1]
		case:
			report(p, .Invalid_Unroll_Loop, for_tok.start)
			bad_stmt = true
		}
	}

	in_tok := expect_token(p, .In)

	prev_allow_range := p.allow_range
	prev_level := p.expr_level
	p.allow_range = true
	p.expr_level = -1
	expr := parse_expr(p, false)
	p.expr_level = prev_level
	p.allow_range = prev_allow_range

	body := parse_control_body(p, for_tok.end, false)

	if bad_stmt {
		return add_node(p, .Bad_Stmt, tag.start, p.prev.end, Bad_Stmt{})
	}
	return add_node(
		p,
		.Unroll_Range_Stmt,
		tag.start,
		p.prev.end,
		Unroll_Range_Stmt {
			unroll_pos = tag.start,
			args = ast_add_list(p.ast, args[:]),
			for_pos = for_tok.start,
			val0 = val0,
			val1 = val1,
			in_pos = in_tok.start,
			expr = expr,
			body = body,
		},
	)
}

parse_stmt :: proc(p: ^Parser) -> Node_Index {
	#partial switch p.curr.kind {
	case .Context,
	     .Proc,
	     .Ident,
	     .Integer,
	     .Float,
	     .Imag,
	     .Rune,
	     .String,
	     .Raw_String,
	     .Open_Paren,
	     .Pointer,
	     .Asm,
	     .Add,
	     .Sub,
	     .Xor,
	     .Not,
	     .And,
	     .Increment,
	     .Decrement:
		stmt := parse_simple_stmt(p, {.Label})
		expect_semicolon(p, stmt)
		return stmt
	case .Foreign:
		return parse_foreign_decl(p)
	case .Import:
		return parse_import_decl(p, false)
	case .If:
		return parse_if_stmt(p)
	case .When:
		return parse_when_stmt(p)
	case .For:
		return parse_for_stmt(p)
	case .Switch:
		return parse_switch_stmt(p)
	case .Defer:
		return parse_defer_stmt(p)
	case .Return:
		return parse_return_stmt(p)
	case .Break, .Continue, .Fallthrough:
		return parse_branch_stmt(p)
	case .Using:
		return parse_using_stmt(p)
	case .At:
		tok := advance_token(p)
		return parse_attribute(p, tok)
	case .Directive:
		return parse_directive_stmt(p)
	case .Open_Brace:
		return parse_block_stmt(p, false)
	case .Semicolon:
		tok := advance_token(p)
		return add_node(p, .Empty_Stmt, tok.start, tok.end, Empty_Stmt{semicolon = tok.start})
	case .Else:
		else_tok := expect_token(p, .Else)
		report(p, .Misplaced_Statement, else_tok.start)
		#partial switch p.curr.kind {
		case .If:
			return parse_if_stmt(p)
		case .When:
			return parse_when_stmt(p)
		case .Open_Brace:
			return parse_block_stmt(p, true)
		case .Do:
			expect_token(p, .Do)
			return parse_do_body(p, else_tok.end)
		case:
			fix_advance_to_next_stmt(p)
			return add_node(p, .Bad_Stmt, else_tok.start, p.prev.end, Bad_Stmt{})
		}
	}

	tok := advance_token(p)
	report(p, .Expected_Statement, tok.start)
	fix_advance_to_next_stmt(p)
	return add_node(p, .Bad_Stmt, tok.start, tok.end, Bad_Stmt{})
}

parse_directive_stmt :: proc(p: ^Parser) -> Node_Index {
	tok := advance_token(p)
	name := token_text(p.tokenizer.source, tok)[1:]
	switch name {
	case "bounds_check", "no_bounds_check":
		stmt := parse_stmt(p)
		flag := Node_Flag.Bounds_Check if name == "bounds_check" else Node_Flag.No_Bounds_Check
		p.ast.nodes[stmt].flags += {flag}
		return stmt
	case "type_assert", "no_type_assert":
		stmt := parse_stmt(p)
		flag := Node_Flag.Type_Assert if name == "type_assert" else Node_Flag.No_Type_Assert
		p.ast.nodes[stmt].flags += {flag}
		return stmt
	case "partial":
		stmt := parse_stmt(p)
		if !set_partial(p, stmt) {
			report(p, .Misplaced_Statement, tok.start)
		}
		return stmt
	case "reverse":
		stmt := parse_stmt(p)
		if !set_reverse(p, stmt) {
			report(p, .Misplaced_Statement, tok.start)
		}
		return stmt
	case "assert", "panic":
		directive := add_node(p, .Basic_Directive, tok.start, tok.end, Basic_Directive{})
		call := parse_call_expr(p, directive)
		start, end := node_span(p.ast, call)
		return add_node(p, .Expr_Stmt, start, end, Expr_Stmt{expr = call})
	case "force_inline", "force_no_inline", "must_tail":
		expr := parse_inlining_or_tailing_operand(p, true, tok)
		start, end := node_span(p.ast, expr)
		return add_node(p, .Expr_Stmt, start, end, Expr_Stmt{expr = expr})
	case "unroll":
		return parse_unrolled_for_loop(p, tok)
	case "include":
		report(p, .Unknown_Directive, tok.start)
		return add_node(p, .Bad_Stmt, tok.start, p.prev.end, Bad_Stmt{})
	}
	stmt := parse_stmt(p)
	return add_node(p, .Tag_Stmt, tok.start, p.prev.end, Tag_Stmt{op = tok, stmt = stmt})
}

parse_defer_stmt :: proc(p: ^Parser) -> Node_Index {
	defer_tok := expect_token(p, .Defer)
	stmt := parse_stmt(p)
	#partial switch p.ast.nodes[stmt].kind {
	case .Empty_Stmt, .Return_Stmt:
		report(p, .Misplaced_Statement, p.ast.nodes[stmt].start)
	case .Defer_Stmt:
		report(p, .Misplaced_Statement, p.ast.nodes[stmt].start)
		stmt = node_payload(p.ast, stmt, Defer_Stmt).stmt
	}
	return add_node(p, .Defer_Stmt, defer_tok.start, p.prev.end, Defer_Stmt{stmt = stmt})
}

parse_return_stmt :: proc(p: ^Parser) -> Node_Index {
	return_tok := expect_token(p, .Return)
	if p.expr_level > 0 {
		report(p, .Misplaced_Statement, return_tok.start)
	}
	results := make([dynamic]Node_Index, 0, 2, p.allocator)
	defer delete(results)
	for p.curr.kind != .Semicolon && p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
		push(p, &results, parse_expr(p, false))
		if p.curr.kind != .Comma {
			break
		}
		advance_token(p)
	}

	end := return_tok.end
	if len(results) > 0 {
		_, end = node_span(p.ast, results[len(results) - 1])
	}
	stmt := add_node(p, .Return_Stmt, return_tok.start, end, Return_Stmt{results = ast_add_list(p.ast, results[:])})
	expect_semicolon(p, stmt)
	return stmt
}

parse_branch_stmt :: proc(p: ^Parser) -> Node_Index {
	tok := advance_token(p)
	label: Node_Index
	if tok.kind != .Fallthrough && p.curr.kind == .Ident {
		label = parse_ident(p)
	}
	stmt := add_node(p, .Branch_Stmt, tok.start, p.prev.end, Branch_Stmt{token = tok, label = label})
	expect_semicolon(p, stmt)
	return stmt
}

parse_using_stmt :: proc(p: ^Parser) -> Node_Index {
	using_tok := expect_token(p, .Using)
	if p.curr.kind == .Import {
		return parse_import_decl(p, true)
	}

	list := parse_expr_list(p, true)
	if p.curr.kind != .Colon {
		last := node_list(p.ast, list)[list.count - 1]
		expect_semicolon(p, last)
		return add_node(p, .Using_Stmt, using_tok.start, p.prev.end, Using_Stmt{list = list})
	}
	expect_token(p, .Colon)
	decl := parse_value_decl(p, list)
	if p.ast.nodes[decl].kind == .Value_Decl {
		payload := node_payload(p.ast, decl, Value_Decl)
		payload.is_using = true
		p.ast.nodes[decl].payload = payload
		return decl
	}
	report(p, .Misplaced_Statement, using_tok.start)
	return add_node(p, .Bad_Stmt, using_tok.start, p.prev.end, Bad_Stmt{})
}

set_partial :: proc(p: ^Parser, stmt: Node_Index) -> bool {
	#partial switch p.ast.nodes[stmt].kind {
	case .Switch_Stmt:
		payload := node_payload(p.ast, stmt, Switch_Stmt)
		payload.partial = true
		p.ast.nodes[stmt].payload = payload
	case .Type_Switch_Stmt:
		payload := node_payload(p.ast, stmt, Type_Switch_Stmt)
		payload.partial = true
		p.ast.nodes[stmt].payload = payload
	case:
		return false
	}
	return true
}

set_reverse :: proc(p: ^Parser, stmt: Node_Index) -> bool {
	if p.ast.nodes[stmt].kind != .Range_Stmt {
		return false
	}
	payload := node_payload(p.ast, stmt, Range_Stmt)
	payload.reverse = true
	p.ast.nodes[stmt].payload = payload
	return true
}

set_stmt_label :: proc(p: ^Parser, stmt: Node_Index, label: Node_Index) {
	p.ast.nodes[stmt].start = min(p.ast.nodes[stmt].start, p.ast.nodes[label].start)
	#partial switch p.ast.nodes[stmt].kind {
	case .Block_Stmt:
		payload := node_payload(p.ast, stmt, Block_Stmt)
		payload.label = label
		p.ast.nodes[stmt].payload = payload
	case .If_Stmt:
		payload := node_payload(p.ast, stmt, If_Stmt)
		payload.label = label
		p.ast.nodes[stmt].payload = payload
	case .For_Stmt:
		payload := node_payload(p.ast, stmt, For_Stmt)
		payload.label = label
		p.ast.nodes[stmt].payload = payload
	case .Range_Stmt:
		payload := node_payload(p.ast, stmt, Range_Stmt)
		payload.label = label
		p.ast.nodes[stmt].payload = payload
	case .Switch_Stmt:
		payload := node_payload(p.ast, stmt, Switch_Stmt)
		payload.label = label
		p.ast.nodes[stmt].payload = payload
	case .Type_Switch_Stmt:
		payload := node_payload(p.ast, stmt, Type_Switch_Stmt)
		payload.label = label
		p.ast.nodes[stmt].payload = payload
	}
}

parse_simple_stmt :: proc(p: ^Parser, flags: Stmt_Allow_Flags) -> Node_Index {
	lhs := parse_expr_list(p, true)
	start, _ := range_span(p, lhs)
	op := p.curr
	switch {
	case is_assignment_operator(op.kind):
		advance_token(p)
		rhs := parse_expr_list(p, false)
		return add_node(p, .Assign_Stmt, start, p.prev.end, Assign_Stmt{lhs = lhs, op = op, rhs = rhs})
	case op.kind == .In && .In in flags:
		advance_token(p)
		prev_allow_range := p.allow_range
		p.allow_range = true
		expr := parse_expr(p, false)
		p.allow_range = prev_allow_range
		return add_node(p, .Assign_Stmt, start, p.prev.end, Assign_Stmt{lhs = lhs, op = op, rhs = ast_add_list(p.ast, []Node_Index{expr})})
	case op.kind == .Colon:
		expect_token(p, .Colon)
		if .Label in flags && lhs.count == 1 {
			label := node_list(p.ast, lhs)[0]
			is_partial, is_reverse := false, false
			if p.curr.kind == .Directive {
				text := token_text(p.tokenizer.source, p.curr)
				next := peek_token(p, 0).kind
				if text == "#partial" && next == .Switch {
					advance_token(p)
					is_partial = true
				} else if text == "#reverse" && next == .For {
					advance_token(p)
					is_reverse = true
				}
			}
			#partial switch p.curr.kind {
			case .Open_Brace, .If, .For, .Switch:
				stmt := parse_stmt(p)
				set_stmt_label(p, stmt, label)
				if is_partial && !set_partial(p, stmt) {
					report(p, .Misplaced_Statement, p.ast.nodes[stmt].start)
				}
				if is_reverse && !set_reverse(p, stmt) {
					report(p, .Misplaced_Statement, p.ast.nodes[stmt].start)
				}
				return stmt
			}
		}
		return parse_value_decl(p, lhs)
	}

	if lhs.count > 1 {
		report(p, .Expected_Single_Expression, op.start)
		return add_node(p, .Bad_Stmt, start, p.prev.end, Bad_Stmt{})
	}
	expr := node_list(p.ast, lhs)[0]
	expr_start, expr_end := node_span(p.ast, expr)
	return add_node(p, .Expr_Stmt, expr_start, expr_end, Expr_Stmt{expr = expr})
}

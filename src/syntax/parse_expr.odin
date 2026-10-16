package syntax

// Expression entry points never return the none handle 0: a missing operand becomes a Bad_Expr,
// so callers can always read the returned node's span.

parse_expr :: proc(p: ^Parser, lhs: bool) -> Node_Index {
	return parse_binary_expr(p, lhs, 1)
}

parse_expr_list :: proc(p: ^Parser, lhs: bool) -> Node_Range {
	list := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(list)
	for {
		append(&list, parse_expr(p, lhs))
		if !allow_token(p, .Comma) {
			break
		}
	}
	return ast_add_list(p.ast, list[:])
}

parse_unary_expr :: proc(p: ^Parser, lhs: bool) -> Node_Index {
	#partial switch p.curr.kind {
	case .Transmute, .Cast:
		tok := advance_token(p)
		open := expect_token(p, .Open_Paren)
		type := parse_type(p)
		close := expect_closing(p, .Close_Paren)
		expr := parse_unary_expr(p, lhs)
		return add_node(p, .Type_Cast, tok.start, p.prev.end, Type_Cast{
			token = tok,
			open  = open.start,
			type  = type,
			close = close.start,
			expr  = expr,
		})

	case .Auto_Cast:
		op := advance_token(p)
		expr := parse_unary_expr(p, lhs)
		return add_node(p, .Auto_Cast, op.start, p.prev.end, Auto_Cast{op = op, expr = expr})

	case .Add, .Sub, .Not, .Xor, .And, .Mul_Mul:
		op := advance_token(p)
		expr := parse_unary_expr(p, lhs)
		return add_node(p, .Unary_Expr, op.start, p.prev.end, Unary_Expr{op = op, expr = expr})

	case .Increment, .Decrement:
		op := advance_token(p)
		report(p, .Unsupported_Operator, op.start)
		expr := parse_unary_expr(p, lhs)
		return add_node(p, .Unary_Expr, op.start, p.prev.end, Unary_Expr{op = op, expr = expr})

	case .Period:
		op := advance_token(p)
		field: Node_Index
		if p.curr.kind == .Ident && !is_decl_on_later_line(p) {
			field = parse_ident(p)
		} else {
			report(p, .Expected_Selector, op.end)
			field = add_node(p, .Ident, op.end, op.end, Ident{})
		}
		return add_node(p, .Implicit_Selector_Expr, op.start, p.prev.end, Implicit_Selector_Expr{field = field})
	}
	return parse_atom_expr(p, parse_operand(p, lhs), lhs)
}

parse_binary_expr :: proc(p: ^Parser, lhs: bool, prec_in: int) -> Node_Index {
	expr := parse_unary_expr(p, lhs)

	for prec := token_precedence(p, p.curr.kind); prec >= prec_in; prec -= 1 {
		loop: for {
			op := p.curr
			if token_precedence(p, op.kind) != prec {
				break loop
			}
			// An `if` or `when` on a later line ends the statement unless it is nested in an expression.
			if (op.kind == .If || op.kind == .When) && p.expr_level <= 0 && newline_before(p, op) {
				break loop
			}

			expect_operator(p)
			start := start_of(p, expr)

			#partial switch op.kind {
			case .Question:
				cond := expr
				x := parse_expr(p, lhs)
				colon := expect_token(p, .Colon)
				y := parse_expr(p, lhs)
				expr = add_node(p, .Ternary_If_Expr, start, p.prev.end, Ternary_Expr{
					x    = x,
					op1  = op,
					cond = cond,
					op2  = colon,
					y    = y,
				})

			case .If:
				x := expr
				cond := parse_expr(p, lhs)
				else_tok := expect_token(p, .Else)
				y := parse_expr(p, lhs)
				expr = add_node(p, .Ternary_If_Expr, start, p.prev.end, Ternary_Expr{
					x    = x,
					op1  = op,
					cond = cond,
					op2  = else_tok,
					y    = y,
				})

			case .When:
				x := expr
				cond := parse_expr(p, lhs)
				skip_possible_newline(p)
				else_tok := expect_token(p, .Else)
				y := parse_expr(p, lhs)
				expr = add_node(p, .Ternary_When_Expr, start, p.prev.end, Ternary_Expr{
					x    = x,
					op1  = op,
					cond = cond,
					op2  = else_tok,
					y    = y,
				})

			case .Or_Else:
				x := expr
				y := parse_expr(p, lhs)
				expr = add_node(p, .Or_Else_Expr, start, p.prev.end, Or_Else_Expr{x = x, token = op, y = y})

			case:
				right := parse_binary_expr(p, false, prec + 1)
				expr = add_node(p, .Binary_Expr, start, p.prev.end, Binary_Expr{left = expr, op = op, right = right})
			}
		}
	}

	return expr
}

token_precedence :: proc(p: ^Parser, kind: Token_Kind) -> int {
	#partial switch kind {
	case .Question, .If, .When, .Or_Else:
		return 1
	case .Ellipsis, .Range_Half, .Range_Full:
		if !p.allow_range {
			return 0
		}
		return 2
	case .Cmp_Or:
		return 3
	case .Cmp_And:
		return 4
	case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		return 5
	case .In, .Not_In:
		if p.expr_level < 0 && !p.allow_in_expr {
			return 0
		}
		fallthrough
	case .Add, .Sub, .Or, .Xor:
		return 6
	case .Mul, .Quo, .Mod, .Mod_Mod, .And, .And_Not, .Shl, .Shr:
		return 7
	}
	return 0
}

// expect_operator consumes the operator of a binary expression. Only `if`, `when`, `or_else`, `in`
// and `not in` may appear there without being operator kinds.
expect_operator :: proc(p: ^Parser) -> Token {
	prev := p.curr
	#partial switch prev.kind {
	case .If, .When, .Or_Else, .In, .Not_In:
	case:
		if !is_operator(prev.kind) {
			report(p, .Expected_Operator, prev.start)
		}
	}
	advance_token(p)
	return prev
}

skip_possible_newline :: proc(p: ^Parser) {
	if is_inserted_semicolon(p.curr) {
		advance_token(p)
	}
}

// is_decl_on_later_line reports whether the current identifier starts a `name :: ` or `name := `
// declaration on a new line, which ends an unclosed list.
is_decl_on_later_line :: proc(p: ^Parser) -> bool {
	if p.curr.kind != .Ident || !newline_before(p, p.curr) {
		return false
	}
	if peek_token(p, 0).kind != .Colon {
		return false
	}
	next := peek_token(p, 1).kind
	return next == .Colon || next == .Eq
}

unparen :: proc(p: ^Parser, index: Node_Index) -> Node_Index {
	current := index
	for p.ast.nodes[current].kind == .Paren_Expr {
		current = node_payload(p.ast, current, Paren_Expr).expr
	}
	return current
}

is_literal_type :: proc(p: ^Parser, index: Node_Index) -> bool {
	#partial switch p.ast.nodes[unparen(p, index)].kind {
	case .Bad_Expr, .Ident, .Selector_Expr, .Array_Type, .Struct_Type, .Union_Type, .Enum_Type,
	     .Dynamic_Array_Type, .Fixed_Capacity_Dynamic_Array_Type, .Map_Type, .Bit_Set_Type,
	     .Matrix_Type, .Call_Expr, .Bit_Field_Type:
		return true
	}
	return false
}

is_non_inserted_semicolon :: proc(tok: Token) -> bool {
	return tok.kind == .Semicolon && !is_inserted_semicolon(tok)
}

is_unclosed_list_end :: proc(p: ^Parser, closing: Token_Kind) -> bool {
	if closing != .Close_Brace && p.curr.kind == .Close_Brace {
		return true
	}
	return is_decl_on_later_line(p)
}

// expect_closing_token consumes `closing`, allowing one newline before it. On a mismatch it
// skips to the closer, a statement break or EOF, so the enclosing list can finish.
expect_closing_token :: proc(p: ^Parser, closing: Token_Kind) -> Token {
	if is_inserted_semicolon(p.curr) {
		advance_token(p)
	}
	if p.curr.kind == closing {
		return advance_token(p)
	}
	report(p, .Expected_Token, p.curr.start, closing)
	for p.curr.kind != closing && p.curr.kind != .EOF && !is_non_inserted_semicolon(p.curr) && !is_decl_on_later_line(p) {
		advance_token(p)
	}
	if p.curr.kind == closing {
		return advance_token(p)
	}
	return Token{kind = closing, start = p.curr.start, end = p.curr.start}
}

parse_value :: proc(p: ^Parser) -> Node_Index {
	prev_allow_range := p.allow_range
	defer p.allow_range = prev_allow_range
	p.allow_range = true
	return parse_expr(p, false)
}

parse_elem_list :: proc(p: ^Parser) -> Node_Range {
	elems := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(elems)
	for p.curr.kind != .Close_Brace && p.curr.kind != .EOF && !is_unclosed_list_end(p, .Close_Brace) {
		elem := parse_value(p)
		if p.curr.kind == .Eq {
			eq := expect_token(p, .Eq)
			value := parse_value(p)
			elem = add_node(p, .Field_Value, start_of(p, elem), p.prev.end, Field_Value{field = elem, sep = eq.start, value = value})
		}
		append(&elems, elem)
		if !allow_token(p, .Comma) {
			break
		}
	}
	return ast_add_list(p.ast, elems[:])
}

parse_literal_value :: proc(p: ^Parser, type: Node_Index) -> Node_Index {
	open := expect_token(p, .Open_Brace)
	prev_expr_level := p.expr_level
	p.expr_level = 0
	elems: Node_Range
	if p.curr.kind != .Close_Brace {
		elems = parse_elem_list(p)
	}
	p.expr_level = prev_expr_level

	skip_possible_newline(p)
	close := expect_closing_token(p, .Close_Brace)

	start := open.start
	if type != 0 {
		start = p.ast.nodes[type].start
	}
	return add_node(p, .Comp_Lit, start, close.end, Comp_Lit{type = type, open = open.start, elems = elems, close = close.start})
}

empty_selector_expr :: proc(p: ^Parser, operand: Node_Index, tok: Token) -> Node_Index {
	field := add_node(p, .Ident, tok.end, tok.end, Ident{})
	return add_node(p, .Selector_Expr, start_of(p, operand), tok.end, Selector_Expr{expr = operand, op = tok, field = field})
}

parse_field_selector :: proc(p: ^Parser, operand: Node_Index, tok: Token) -> Node_Index {
	if p.curr.kind != .Ident || is_decl_on_later_line(p) {
		report(p, .Expected_Selector, p.curr.start)
		return empty_selector_expr(p, operand, tok)
	}
	field := parse_ident(p)
	return add_node(p, .Selector_Expr, start_of(p, operand), p.prev.end, Selector_Expr{expr = operand, op = tok, field = field})
}

parse_call_expr :: proc(p: ^Parser, operand: Node_Index) -> Node_Index {
	args := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(args)

	ellipsis: Token
	seen_ellipsis := false
	prev_expr_level := p.expr_level
	p.expr_level = 0
	open := expect_token(p, .Open_Paren)

	for p.curr.kind != .Close_Paren && p.curr.kind != .EOF && !is_unclosed_list_end(p, .Close_Paren) {
		if p.curr.kind == .Comma || p.curr.kind == .Eq {
			report(p, .Expected_Operand, p.curr.start)
		}

		prefix_ellipsis := false
		if p.curr.kind == .Ellipsis {
			prefix_ellipsis = true
			ellipsis = expect_token(p, .Ellipsis)
		}

		arg := parse_expr(p, false)
		if p.curr.kind == .Eq {
			eq := expect_token(p, .Eq)
			if prefix_ellipsis {
				report(p, .Spread_On_Field, ellipsis.start)
			}
			value := parse_value(p)
			arg = add_node(p, .Field_Value, start_of(p, arg), p.prev.end, Field_Value{field = arg, sep = eq.start, value = value})
		} else if seen_ellipsis {
			report(p, .Positional_After_Ellipsis, p.ast.nodes[arg].start)
		}
		append(&args, arg)

		if ellipsis.kind != .Invalid {
			seen_ellipsis = true
		}
		if !allow_token(p, .Comma) {
			break
		}
	}

	p.expr_level = prev_expr_level
	close := expect_closing_token(p, .Close_Paren)

	call := add_node(p, .Call_Expr, start_of(p, operand), close.end, Call_Expr{
		expr     = operand,
		open     = open.start,
		args     = ast_add_list(p.ast, args[:]),
		ellipsis = ellipsis,
		close    = close.start,
	})

	callee := unparen(p, operand)
	if p.ast.nodes[callee].kind == .Selector_Expr && node_payload(p.ast, callee, Selector_Expr).op.kind == .Arrow_Right {
		return add_node(p, .Selector_Call_Expr, p.ast.nodes[call].start, close.end, Selector_Call_Expr{expr = callee, call = call})
	}
	return call
}

parse_atom_expr :: proc(p: ^Parser, value: Node_Index, lhs: bool) -> Node_Index {
	operand := value
	is_lhs := lhs
	loop: for {
		#partial switch p.curr.kind {
		case .Open_Paren:
			operand = parse_call_expr(p, operand)

		case .Open_Bracket:
			prev_allow_range := p.allow_range
			p.allow_range = false
			p.expr_level += 1
			open := expect_token(p, .Open_Bracket)

			indices: [2]Node_Index
			interval: Token
			is_slice_op := false

			#partial switch p.curr.kind {
			case .Colon, .Ellipsis, .Range_Half, .Range_Full:
			case .Close_Brace:
				indices[0] = add_node(p, .Bad_Expr, p.curr.start, p.curr.start, Bad_Expr{})
			case:
				indices[0] = parse_expr(p, false)
			}

			#partial switch p.curr.kind {
			case .Ellipsis, .Range_Half, .Range_Full:
				report(p, .Expected_Token, p.curr.start, .Colon)
				fallthrough
			case .Colon, .Comma:
				interval = advance_token(p)
				is_slice_op = true
				if p.curr.kind != .Close_Bracket && p.curr.kind != .EOF {
					indices[1] = parse_expr(p, false)
				}
			}

			p.expr_level -= 1
			close := expect_closing(p, .Close_Bracket)
			p.allow_range = prev_allow_range

			start := start_of(p, operand)
			if !is_slice_op {
				operand = add_node(p, .Index_Expr, start, close.end, Index_Expr{expr = operand, open = open.start, index = indices[0], close = close.start})
			} else if interval.kind == .Comma {
				if indices[0] == 0 || indices[1] == 0 {
					report(p, .Missing_Matrix_Index, close.start)
				}
				operand = add_node(p, .Matrix_Index_Expr, start, close.end, Matrix_Index_Expr{
					expr         = operand,
					open         = open.start,
					row_index    = indices[0],
					column_index = indices[1],
					close        = close.start,
				})
			} else {
				operand = add_node(p, .Slice_Expr, start, close.end, Slice_Expr{
					expr     = operand,
					open     = open.start,
					low      = indices[0],
					interval = interval,
					high     = indices[1],
					close    = close.start,
				})
			}

		case .Period:
			tok := expect_token(p, .Period)
			#partial switch p.curr.kind {
			case .Open_Paren:
				open := expect_token(p, .Open_Paren)
				type := parse_type(p)
				close := expect_closing(p, .Close_Paren)
				operand = add_node(p, .Type_Assertion, start_of(p, operand), close.end, Type_Assertion{
					expr  = operand,
					dot   = tok.start,
					open  = open.start,
					type  = type,
					close = close.start,
				})

			case .Question:
				question := expect_token(p, .Question)
				type := add_node(p, .Unary_Expr, question.start, question.end, Unary_Expr{op = question})
				operand = add_node(p, .Type_Assertion, start_of(p, operand), question.end, Type_Assertion{
					expr = operand,
					dot  = tok.start,
					type = type,
				})

			case:
				operand = parse_field_selector(p, operand, tok)
			}

		case .Arrow_Right:
			tok := expect_token(p, .Arrow_Right)
			operand = parse_field_selector(p, operand, tok)

		case .Pointer:
			op := expect_token(p, .Pointer)
			operand = add_node(p, .Deref_Expr, start_of(p, operand), op.end, Deref_Expr{expr = operand, op = op})

		case .Or_Return:
			token := expect_token(p, .Or_Return)
			operand = add_node(p, .Or_Return_Expr, start_of(p, operand), token.end, Or_Return_Expr{expr = operand, token = token})

		case .Or_Break, .Or_Continue:
			token := advance_token(p)
			label: Node_Index
			end := token.end
			if p.curr.kind == .Ident {
				label = parse_ident(p)
				end = p.prev.end
			}
			operand = add_node(p, .Or_Branch_Expr, start_of(p, operand), end, Or_Branch_Expr{expr = operand, token = token, label = label})

		case .Open_Brace:
			if is_lhs || !is_literal_type(p, operand) || p.expr_level < 0 {
				break loop
			}
			operand = parse_literal_value(p, operand)

		case .Increment, .Decrement:
			if lhs {
				break loop
			}
			tok := advance_token(p)
			report(p, .Unsupported_Operator, tok.start)

		case:
			break loop
		}
		is_lhs = false
	}
	return operand
}

parse_operand :: proc(p: ^Parser, lhs: bool) -> Node_Index {
	#partial switch p.curr.kind {
	case .Ident:
		if !lhs && is_decl_on_later_line(p) {
			report(p, .Expected_Operand, p.prev.end)
			return add_node(p, .Bad_Expr, p.prev.end, p.prev.end, Bad_Expr{})
		}
		return parse_ident(p)

	case .Undef:
		tok := expect_token(p, .Undef)
		return add_node(p, .Undef, tok.start, tok.end, Undef{})

	case .Context:
		tok := expect_token(p, .Context)
		return add_node(p, .Implicit, tok.start, tok.end, Implicit{kind = tok.kind})

	case .Integer, .Float, .Imag, .Rune, .String, .Raw_String:
		tok := advance_token(p)
		return add_node(p, .Basic_Lit, tok.start, tok.end, Basic_Lit{kind = tok.kind})

	case .Open_Brace:
		if !lhs {
			return parse_literal_value(p, 0)
		}

	case .Open_Paren:
		open := expect_token(p, .Open_Paren)
		prev_expr_level := p.expr_level
		p.expr_level = max(p.expr_level, 0) + 1
		expr := parse_expr(p, false)
		p.expr_level = prev_expr_level
		close := expect_closing(p, .Close_Paren)
		return add_node(p, .Paren_Expr, open.start, close.end, Paren_Expr{open = open.start, expr = expr, close = close.start})

	case .Distinct:
		tok := advance_token(p)
		type := parse_type(p)
		return add_node(p, .Distinct_Type, tok.start, p.prev.end, Distinct_Type{type = type})

	case .Directive:
		return parse_directive_expr(p, lhs)

	case .Proc:
		return parse_proc_expr(p)

	case .Dollar:
		tok := advance_token(p)
		type := parse_ident(p)
		end := p.ast.nodes[type].end
		specialization: Node_Index
		if allow_token(p, .Quo) {
			specialization = parse_type(p)
			end = p.prev.end
		}
		if is_blank_ident(p, type) {
			report(p, .Blank_Poly_Name, p.ast.nodes[type].start)
		}
		return add_node(p, .Poly_Type, tok.start, end, Poly_Type{dollar = tok.start, type = type, specialization = specialization})

	case .Typeid:
		tok := advance_token(p)
		return add_node(p, .Typeid_Type, tok.start, tok.end, Typeid_Type{})

	case .Pointer:
		tok := expect_token(p, .Pointer)
		elem := parse_type(p)
		return add_node(p, .Pointer_Type, tok.start, p.prev.end, Pointer_Type{pointer = tok.start, elem = elem})

	case .Open_Bracket:
		return parse_bracket_type(p)

	case .Map:
		return parse_map_type(p)

	case .Struct:
		return parse_struct_type(p)

	case .Union:
		return parse_union_type(p)

	case .Enum:
		return parse_enum_type(p)

	case .Bit_Set:
		return parse_bit_set_type(p)

	case .Matrix:
		return parse_matrix_type(p)

	case .Bit_Field:
		return parse_bit_field_type(p)

	case .Asm:
		tok := advance_token(p)
		report(p, .Unsupported_Construct, tok.start)
		return add_node(p, .Bad_Expr, tok.start, tok.end, Bad_Expr{})
	}
	report(p, .Expected_Operand, p.curr.start)
	return add_node(p, .Bad_Expr, p.curr.start, p.curr.start, Bad_Expr{})
}

parse_directive_expr :: proc(p: ^Parser, lhs: bool) -> Node_Index {
	tok := advance_token(p)
	name := token_text(p.tokenizer.source, tok)[1:]
	switch name {
	case "":
		report(p, .Expected_Token, tok.end, .Ident)
		return add_node(p, .Bad_Expr, tok.start, tok.end, Bad_Expr{})

	case "type":
		type := parse_type(p)
		return add_node(p, .Helper_Type, tok.start, p.prev.end, Helper_Type{type = type})

	case "file", "directory", "line", "procedure", "caller_location":
		return add_node(p, .Basic_Directive, tok.start, tok.end, Basic_Directive{})

	case "caller_expression":
		directive := add_node(p, .Basic_Directive, tok.start, tok.end, Basic_Directive{})
		if p.curr.kind == .Open_Paren {
			return parse_call_expr(p, directive)
		}
		return directive

	case "location", "exists", "load", "load_directory", "load_hash", "hash", "assert", "panic", "defined", "config":
		directive := add_node(p, .Basic_Directive, tok.start, tok.end, Basic_Directive{})
		return parse_call_expr(p, directive)

	case "soa":
		directive := add_node(p, .Basic_Directive, tok.start, tok.end, Basic_Directive{})
		original := parse_type(p)
		if !set_tag(p, unparen(p, original), directive) {
			report(p, .Expected_Type, p.ast.nodes[original].start)
		}
		return original

	case "simd", "sparse":
		directive := add_node(p, .Basic_Directive, tok.start, tok.end, Basic_Directive{})
		original := parse_type(p)
		target := unparen(p, original)
		if p.ast.nodes[target].kind != .Array_Type {
			report(p, .Expected_Type, p.ast.nodes[original].start)
		} else {
			set_tag(p, target, directive)
		}
		return original

	case "partial":
		directive := add_node(p, .Basic_Directive, tok.start, tok.end, Basic_Directive{})
		original := parse_expr(p, lhs)
		target := unparen(p, original)
		#partial switch p.ast.nodes[target].kind {
		case .Comp_Lit:
			set_tag(p, target, directive)
		case .Array_Type:
			set_tag(p, target, directive)
			report(p, .Unknown_Directive, tok.start)
		case:
			report(p, .Expected_Operand, tok.start)
		}
		return original

	case "bounds_check", "no_bounds_check":
		operand := parse_expr(p, lhs)
		flag := Node_Flag.Bounds_Check
		opposite := Node_Flag.No_Bounds_Check
		if name == "no_bounds_check" {
			flag, opposite = opposite, flag
		}
		if opposite in p.ast.nodes[operand].flags {
			report(p, .Illegal_Directive_Combination, tok.start)
		}
		p.ast.nodes[operand].flags += {flag}
		return operand

	case "relative":
		directive := add_node(p, .Basic_Directive, tok.start, tok.end, Basic_Directive{})
		tag := parse_call_expr(p, directive)
		type := parse_type(p)
		return add_node(p, .Relative_Type, tok.start, p.prev.end, Relative_Type{tag = tag, type = type})

	case "force_inline", "force_no_inline":
		return parse_inlining_or_tailing_operand(p, lhs, tok)

	case:
		expr := parse_expr(p, lhs)
		return add_node(p, .Tag_Expr, tok.start, p.prev.end, Tag_Expr{op = tok, expr = expr})
	}
}

parse_inlining_or_tailing_operand :: proc(p: ^Parser, lhs: bool, tok: Token) -> Node_Index {
	expr := parse_unary_expr(p, lhs)

	inlining := Proc_Inlining.None
	switch token_text(p.tokenizer.source, tok) {
	case "#force_inline":
		inlining = .Inline
	case "#force_no_inline":
		inlining = .No_Inline
	}

	target := expr
	if p.ast.nodes[target].kind == .Or_Return_Expr {
		target = node_payload(p.ast, target, Or_Return_Expr).expr
	}

	#partial switch p.ast.nodes[target].kind {
	case .Proc_Lit:
		lit := node_payload(p.ast, target, Proc_Lit)
		if lit.inlining != .None && lit.inlining != inlining {
			report(p, .Illegal_Directive_Combination, p.ast.nodes[expr].start)
		}
		lit.inlining = inlining
		p.ast.nodes[target].payload = lit
		return expr
	case .Call_Expr:
		call := node_payload(p.ast, target, Call_Expr)
		if call.inlining != .None && call.inlining != inlining {
			report(p, .Illegal_Directive_Combination, p.ast.nodes[expr].start)
		}
		call.inlining = inlining
		p.ast.nodes[target].payload = call
		return expr
	}
	report(p, .Invalid_Directive_Target, tok.start)
	return add_node(p, .Bad_Expr, tok.start, p.prev.end, Bad_Expr{})
}

// set_tag stores `tag` on a node that has a tag field and reports whether it had one.
set_tag :: proc(p: ^Parser, index: Node_Index, tag: Node_Index) -> bool {
	node := &p.ast.nodes[index]
	node.start = min(node.start, p.ast.nodes[tag].start)
	#partial switch node.kind {
	case .Array_Type:
		payload := node.payload.(Array_Type)
		payload.tag = tag
		node.payload = payload
	case .Dynamic_Array_Type:
		payload := node.payload.(Dynamic_Array_Type)
		payload.tag = tag
		node.payload = payload
	case .Fixed_Capacity_Dynamic_Array_Type:
		payload := node.payload.(Fixed_Capacity_Dynamic_Array_Type)
		payload.tag = tag
		node.payload = payload
	case .Pointer_Type:
		payload := node.payload.(Pointer_Type)
		payload.tag = tag
		node.payload = payload
	case .Comp_Lit:
		payload := node.payload.(Comp_Lit)
		payload.tag = tag
		node.payload = payload
	case:
		return false
	}
	return true
}

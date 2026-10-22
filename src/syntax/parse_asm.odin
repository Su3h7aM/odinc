package syntax

parse_asm_template :: proc(p: ^Parser) -> Node_Index {
	asm_tok := expect_token(p, .Asm)
	signature := parse_proc_type(p, asm_tok)
	skip_possible_newline(p)

	specs, clobbers: Node_Range
	if p.curr.kind == .Open_Bracket {
		specs, clobbers = parse_asm_spec_list(p)
	}

	instructions: Node_Range
	if !allow_token(p, .Open_Brace) {
		report(p, .Missing_Asm_Body, p.curr.start)
		advance_token(p)
	} else {
		instruction_nodes := make([dynamic]Node_Index, 0, 8, p.allocator)
		defer delete(instruction_nodes)
		for p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
			append_present_node(p, &instruction_nodes, parse_asm_instruction(p))
		}
		expect_closing_token(p, .Close_Brace)
		instructions = ast_add_list(p.ast, instruction_nodes[:])
	}

	return add_node(
		p,
		.Asm_Template,
		asm_tok.start,
		p.prev.end,
		Asm_Template{tok_pos = asm_tok.start, type = signature, specs = specs, clobbers = clobbers, instructions = instructions},
	)
}

parse_asm_spec_list :: proc(p: ^Parser) -> (specs, clobbers: Node_Range) {
	spec_nodes := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(spec_nodes)
	clobber_nodes := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(clobber_nodes)

	expect_token(p, .Open_Bracket)
	for p.curr.kind != .Close_Bracket && p.curr.kind != .EOF {
		#partial switch p.curr.kind {
		case .Ident:
			push(p, &spec_nodes, parse_asm_spec(p))
		case .Directive:
			append_present_node(p, &clobber_nodes, parse_asm_clobber(p))
		case:
			report(p, .Invalid_Asm_Specification, p.curr.start)
			advance_token(p)
		}
		if !allow_token(p, .Comma) {
			break
		}
	}
	expect_closing(p, .Close_Bracket)
	skip_possible_newline(p)
	return ast_add_list(p.ast, spec_nodes[:]), ast_add_list(p.ast, clobber_nodes[:])
}

parse_asm_clobber :: proc(p: ^Parser) -> Node_Index {
	directive := advance_token(p)
	name := add_node(p, .Basic_Directive, directive.start, directive.end, Basic_Directive{})
	clobber: Node_Index
	switch token_text(p.tokenizer.source, directive)[1:] {
	case "volatile", "align_stack", "pure":
		clobber = add_node(p, .Asm_Clobber, directive.start, directive.end, Asm_Clobber{name = name})
	case "clobber", "preserve":
		value := parse_asm_operand(p, false)
		clobber = add_node(p, .Asm_Clobber, directive.start, p.prev.end, Asm_Clobber{name = name, value = value})
	case:
		report(p, .Invalid_Asm_Clobber, directive.start)
	}
	return clobber
}

parse_asm_spec :: proc(p: ^Parser) -> Node_Index {
	name := parse_ident(p)
	tied_name, type, value: Node_Index
	if allow_token(p, .Arrow_Right) {
		tied_name = parse_ident(p)
	}
	if allow_token(p, .Colon) {
		type = parse_type(p)
	}
	if allow_token(p, .Eq) {
		#partial switch p.curr.kind {
		case .Ident:
			value = parse_ident(p)
		case .Mod:
			value = parse_asm_register(p)
		case:
			report(p, .Invalid_Asm_Specification, p.curr.start)
			parse_expr(p, true)
		}
	}
	if tied_name != 0 {
		if type != 0 {
			report(p, .Invalid_Asm_Specification, p.curr.start)
		}
	} else if type == 0 && value == 0 {
		report(p, .Invalid_Asm_Specification, p.curr.start)
	}

	directive_nodes := make([dynamic]Node_Index, 0, 2, p.allocator)
	defer delete(directive_nodes)
	for p.curr.kind == .Directive {
		directive := advance_token(p)
		if token_text(p.tokenizer.source, directive) == "#" {
			report(p, .Expected_Token, directive.end, .Ident)
			continue
		}
		push(p, &directive_nodes, add_node(p, .Basic_Directive, directive.start, directive.end, Basic_Directive{}))
	}

	return add_node(
		p,
		.Asm_Spec,
		p.ast.nodes[name].start,
		p.prev.end,
		Asm_Spec{name = name, tied_name = tied_name, type = type, value = value, directives = ast_add_list(p.ast, directive_nodes[:])},
	)
}

parse_asm_register :: proc(p: ^Parser) -> Node_Index {
	mod := expect_token(p, .Mod)
	name := parse_ident(p)
	flag: Node_Index
	if allow_token(p, .Period) {
		flag = parse_ident(p)
	}
	return add_node(p, .Asm_Register, mod.start, p.prev.end, Asm_Register{name = name, flag = flag})
}

parse_asm_label :: proc(p: ^Parser) -> Node_Index {
	period := expect_token(p, .Period)
	name := parse_ident(p)
	return add_node(p, .Asm_Label, period.start, p.prev.end, Asm_Label{name = name})
}

append_present_node :: proc(p: ^Parser, operands: ^[dynamic]Node_Index, operand: Node_Index) {
	if operand != 0 {
		push(p, operands, operand)
	}
}

parse_asm_operand :: proc(p: ^Parser, allow_memory_operand: bool) -> Node_Index {
	operand: Node_Index
	#partial switch p.curr.kind {
	case .Period:
		return parse_asm_label(p)
	case .Ident:
		operand = parse_ident(p)
	case .Mod:
		operand = parse_asm_register(p)
	case .Integer, .Float, .Rune:
		tok := advance_token(p)
		return add_node(p, .Basic_Lit, tok.start, tok.end, Basic_Lit{kind = tok.kind})
	case .Add, .Sub, .Xor:
		op := advance_token(p)
		expr := parse_asm_operand(p, false)
		return add_node(p, .Unary_Expr, op.start, p.prev.end, Unary_Expr{op = op, expr = expr})
	case .Open_Paren:
		return parse_expr(p, false)
	case .Directive:
		tok := advance_token(p)
		name := token_text(p.tokenizer.source, tok)[1:]
		if name == "pre" || name == "post" {
			operand = parse_asm_operand(p, allow_memory_operand)
			if operand == 0 || p.ast.nodes[operand].kind != .Asm_Memory_Operand {
				report(p, .Invalid_Asm_Operand, tok.start)
			} else {
				memory := node_payload(p.ast, operand, Asm_Memory_Operand)
				memory.kind = .Pre if name == "pre" else .Post
				p.ast.nodes[operand].payload = memory
			}
		}
	case .Open_Bracket:
		if allow_memory_operand {
			return parse_asm_memory_operand(p)
		}
	case .Open_Brace:
		if allow_memory_operand {
			return parse_asm_register_group(p)
		}
	}

	if operand == 0 {
		report(p, .Invalid_Asm_Operand, p.curr.start)
		advance_token(p)
		return 0
	}
	if p.curr.kind == .Open_Bracket {
		p.expr_level += 1
		open := expect_token(p, .Open_Bracket)
		index := parse_asm_operand(p, false)
		close := expect_closing(p, .Close_Bracket)
		p.expr_level -= 1
		return add_node(
			p,
			.Index_Expr,
			p.ast.nodes[operand].start,
			p.prev.end,
			Index_Expr{expr = operand, open = open.start, index = index, close = close.start},
		)
	}
	return operand
}

parse_asm_memory_operand :: proc(p: ^Parser) -> Node_Index {
	open := expect_token(p, .Open_Bracket)
	base := parse_asm_operand(p, false)
	segment_override: Node_Index
	if allow_token(p, .Colon) {
		segment_override = base
		if segment_override != 0 && p.ast.nodes[segment_override].kind != .Asm_Register {
			report(p, .Invalid_Asm_Operand, p.ast.nodes[segment_override].start)
		}
		base = parse_asm_operand(p, false)
	}

	index_op, scale_op, disp_op: Token_Kind
	index, scale, disp: Node_Index
	if p.curr.kind == .Add || p.curr.kind == .Sub {
		index_op = advance_token(p).kind
		index = parse_asm_operand(p, false)
		if p.curr.kind == .Mul || p.curr.kind == .Shl || p.curr.kind == .Shr {
			scale_op = advance_token(p).kind
			scale = parse_asm_operand(p, false)
		}
		if p.curr.kind == .Add || p.curr.kind == .Sub {
			disp_op = advance_token(p).kind
			disp = parse_asm_operand(p, false)
		}
	}

	close := expect_closing(p, .Close_Bracket)
	type: Node_Index
	if allow_token(p, .Colon) {
		type = parse_type(p)
	}
	return add_node(
		p,
		.Asm_Memory_Operand,
		open.start,
		p.prev.end,
		Asm_Memory_Operand {
			kind = .Default,
			open = open.start,
			segment_override = segment_override,
			base = base,
			index_op = index_op,
			index = index,
			scale_op = scale_op,
			scale = scale,
			disp_op = disp_op,
			disp = disp,
			close = close.start,
			type = type,
		},
	)
}

parse_asm_register_group :: proc(p: ^Parser) -> Node_Index {
	open := expect_token(p, .Open_Brace)
	registers := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(registers)
	range_token: Token_Kind
	first := parse_asm_operand(p, false)
	if p.curr.kind == .Range_Half || p.curr.kind == .Range_Full {
		range_token = advance_token(p).kind
		append_present_node(p, &registers, first)
		append_present_node(p, &registers, parse_asm_operand(p, false))
		allow_token(p, .Comma)
	} else {
		append_present_node(p, &registers, first)
		allow_token(p, .Comma)
		for p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
			append_present_node(p, &registers, parse_asm_operand(p, false))
			if !allow_token(p, .Comma) {
				break
			}
		}
	}

	close := expect_closing_token(p, .Close_Brace)
	type: Node_Index
	if allow_token(p, .Colon) {
		type = parse_type(p)
	}
	return add_node(
		p,
		.Asm_Register_Group,
		open.start,
		p.prev.end,
		Asm_Register_Group{open = open.start, registers = ast_add_list(p.ast, registers[:]), range_token = range_token, close = close.start, type = type},
	)
}

parse_asm_operands :: proc(p: ^Parser) -> Node_Range {
	operands := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(operands)
	for p.curr.kind != .Semicolon && p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
		append_present_node(p, &operands, parse_asm_operand(p, true))
		if !allow_token(p, .Comma) {
			break
		}
	}
	allow_token(p, .Semicolon)
	return ast_add_list(p.ast, operands[:])
}

parse_asm_instruction :: proc(p: ^Parser) -> Node_Index {
	if allow_token(p, .Semicolon) {
		return 0
	}
	if p.curr.kind == .Ident || is_keyword(p.curr.kind) {
		name_tok := advance_token(p)
		name := add_node(p, .Ident, name_tok.start, name_tok.end, Ident{})
		operands := parse_asm_operands(p)
		return add_node(p, .Asm_Instruction, name_tok.start, p.prev.end, Asm_Instruction{name = name, operands = operands})
	}
	#partial switch p.curr.kind {
	case .Period:
		label := parse_asm_label(p)
		colon := expect_token(p, .Colon)
		return add_node(p, .Asm_Label_Decl, p.ast.nodes[label].start, colon.end, Asm_Label_Decl{label = label})
	case .Directive:
		directive := advance_token(p)
		name := add_node(p, .Basic_Directive, directive.start, directive.end, Basic_Directive{})
		operands := parse_asm_operands(p)
		return add_node(p, .Asm_Directive, directive.start, p.prev.end, Asm_Directive{name = name, operands = operands})
	}
	report(p, .Invalid_Asm_Instruction, p.curr.start)
	advance_token(p)
	return 0
}

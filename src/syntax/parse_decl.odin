package syntax

parse_value_decl :: proc(p: ^Parser, names: Node_Range) -> Node_Index {
	is_mutable := true
	type: Node_Index
	values: Node_Range
	if p.curr.kind != .Eq && p.curr.kind != .Colon {
		type = parse_type_or_ident(p)
	}

	#partial switch p.curr.kind {
	case .Eq, .Colon:
		sep := advance_token(p)
		is_mutable = sep.kind != .Colon
		values = parse_expr_list(p, false)
		if values.count > names.count || (values.count < names.count && !is_mutable) {
			report(p, .Invalid_Value_Decl, p.curr.start)
		}
	}

	last_value: Node_Index
	if values.count > 0 {
		last_value = node_list(p.ast, values)[values.count - 1]
	}
	if p.expr_level >= 0 {
		if p.curr.kind != .Close_Brace || newline_between(p, p.prev.end, p.curr.start) {
			end_node: Node_Index
			if !is_mutable {
				end_node = last_value
			}
			expect_semicolon(p, end_node)
		}
	}

	if p.proc_depth == 0 && values.count > 0 && names.count != values.count {
		report(p, .Invalid_Value_Decl, p.ast.nodes[node_list(p.ast, values)[0]].start)
	}

	start, _ := range_span(p, names)
	return add_node(p, .Value_Decl, start, p.prev.end, Value_Decl{names = names, type = type, values = values, is_mutable = is_mutable})
}

parse_import_decl :: proc(p: ^Parser, is_using: bool) -> Node_Index {
	import_tok := expect_token(p, .Import)

	name: Node_Index
	if p.curr.kind == .Ident {
		name = parse_ident(p)
	}
	path := expect_token(p, .String)
	relpath := add_node(p, .Basic_Lit, path.start, path.end, Basic_Lit{kind = .String})
	if p.proc_depth > 0 {
		report(p, .Misplaced_Statement, import_tok.start)
	}

	decl := add_node(
		p,
		.Import_Decl,
		import_tok.start,
		path.end,
		Import_Decl{is_using = is_using, import_pos = import_tok.start, name = name, relpath = relpath},
	)
	expect_semicolon(p, decl)
	return decl
}

parse_attribute :: proc(p: ^Parser, at_tok: Token) -> Node_Index {
	elems := make([dynamic]Node_Index, 0, 2, p.allocator)
	defer delete(elems)
	open, close: u32
	if p.curr.kind == .Ident {
		open = p.curr.start
		close = p.curr.start
		push(p, &elems, parse_ident(p))
	} else {
		open = expect_token(p, .Open_Paren).start
		p.expr_level += 1
		for p.curr.kind != .Close_Paren && p.curr.kind != .EOF {
			elem := parse_ident(p)
			if p.curr.kind == .Eq {
				eq := expect_token(p, .Eq)
				value := parse_value(p)
				elem = add_node(p, .Field_Value, p.ast.nodes[elem].start, p.prev.end, Field_Value{field = elem, sep = eq.start, value = value})
			}
			push(p, &elems, elem)
			if !allow_token(p, .Comma) {
				break
			}
		}
		p.expr_level -= 1
		close = expect_closing(p, .Close_Paren).start
	}

	attribute := add_node(p, .Attribute, at_tok.start, p.prev.end, Attribute{open = open, elems = ast_add_list(p.ast, elems[:]), close = close})
	skip_possible_newline(p)
	decl := parse_stmt(p)
	if !attach_attribute(p, decl, attribute) {
		report(p, .Invalid_Attribute_Target, p.ast.nodes[decl].start)
	} else {
		p.ast.nodes[decl].start = p.ast.nodes[attribute].start
	}
	return decl
}

attach_attribute :: proc(p: ^Parser, decl, attribute: Node_Index) -> bool {
	#partial switch p.ast.nodes[decl].kind {
	case .Value_Decl:
		payload := node_payload(p.ast, decl, Value_Decl)
		payload.attributes = append_attribute(p, payload.attributes, attribute)
		p.ast.nodes[decl].payload = payload
	case .Foreign_Block_Decl:
		payload := node_payload(p.ast, decl, Foreign_Block_Decl)
		payload.attributes = append_attribute(p, payload.attributes, attribute)
		p.ast.nodes[decl].payload = payload
	case .Foreign_Import_Decl:
		payload := node_payload(p.ast, decl, Foreign_Import_Decl)
		payload.attributes = append_attribute(p, payload.attributes, attribute)
		p.ast.nodes[decl].payload = payload
	case .Import_Decl:
		payload := node_payload(p.ast, decl, Import_Decl)
		payload.attributes = append_attribute(p, payload.attributes, attribute)
		p.ast.nodes[decl].payload = payload
	case:
		return false
	}
	return true
}

append_attribute :: proc(p: ^Parser, attributes: Node_Range, attribute: Node_Index) -> Node_Range {
	old := node_list(p.ast, attributes)
	list := make([dynamic]Node_Index, 0, len(old) + 1, p.allocator)
	defer delete(list)
	for node in old {
		push(p, &list, node)
	}
	push(p, &list, attribute)
	return ast_add_list(p.ast, list[:])
}

parse_foreign_block_decl :: proc(p: ^Parser) -> Node_Index {
	decl := parse_stmt(p)
	#partial switch p.ast.nodes[decl].kind {
	case .Empty_Stmt, .Bad_Stmt, .Bad_Decl:
		return 0
	case .When_Stmt, .Value_Decl:
		return decl
	}
	report(p, .Invalid_Foreign_Declaration, p.ast.nodes[decl].start)
	return 0
}

parse_foreign_block :: proc(p: ^Parser, tok: Token) -> Node_Index {
	foreign_library: Node_Index
	if p.curr.kind == .Open_Brace {
		foreign_library = add_node(p, .Ident, tok.end, tok.end, Ident{})
	} else {
		foreign_library = parse_ident(p)
	}

	prev_in_foreign_block := p.in_foreign_block
	p.in_foreign_block = true
	defer p.in_foreign_block = prev_in_foreign_block

	skip_possible_newline(p)
	open := expect_token(p, .Open_Brace)
	decls := make([dynamic]Node_Index, 0, 8, p.allocator)
	defer delete(decls)
	for p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
		decl := parse_foreign_block_decl(p)
		if decl != 0 {
			push(p, &decls, decl)
		}
	}
	close := expect_token(p, .Close_Brace)

	body := add_node(p, .Block_Stmt, open.start, close.end, Block_Stmt{open = open.start, stmts = ast_add_list(p.ast, decls[:]), close = close.start})
	return add_node(p, .Foreign_Block_Decl, tok.start, close.end, Foreign_Block_Decl{foreign_pos = tok.start, foreign_library = foreign_library, body = body})
}

parse_foreign_decl :: proc(p: ^Parser) -> Node_Index {
	tok := expect_token(p, .Foreign)

	#partial switch p.curr.kind {
	case .Ident, .Open_Brace:
		return parse_foreign_block(p, tok)
	case .Import:
		import_tok := expect_token(p, .Import)
		name: Node_Index
		if p.curr.kind == .Ident {
			name = parse_ident(p)
		}
		if name != 0 && is_blank_ident(p, name) {
			report(p, .Invalid_Foreign_Declaration, p.ast.nodes[name].start)
		}

		paths := make([dynamic]Node_Index, 0, 1, p.allocator)
		defer delete(paths)
		if allow_token(p, .Open_Brace) {
			for p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
				push(p, &paths, parse_expr(p, false))
				if !allow_token(p, .Comma) {
					break
				}
			}
			expect_token(p, .Close_Brace)
		} else {
			path := expect_token(p, .String)
			push(p, &paths, add_node(p, .Basic_Lit, path.start, path.end, Basic_Lit{kind = .String}))
		}
		if len(paths) == 0 {
			report(p, .Invalid_Foreign_Declaration, import_tok.start)
		}

		decl := add_node(
			p,
			.Foreign_Import_Decl,
			tok.start,
			p.prev.end,
			Foreign_Import_Decl{foreign_pos = tok.start, import_pos = import_tok.start, name = name, fullpaths = ast_add_list(p.ast, paths[:])},
		)
		expect_semicolon(p, decl)
		return decl
	}

	report(p, .Invalid_Foreign_Declaration, tok.start)
	return add_node(p, .Bad_Decl, tok.start, tok.end, Bad_Decl{})
}

package syntax

// Field lists are the shared core of parameter, result, struct, union and bit_field bodies.
// Named field groups are built as Field nodes whose names are Ident or Poly_Type nodes.

Field_Prefix_Entry :: struct {
	expr:  Node_Index,
	flags: Field_Flags,
}

field_flags_struct :: Field_Flags{.Using, .Tags, .Subtype}
field_flags_record_poly_params :: Field_Flags{.Typeid_Token, .Default_Parameters}
field_flags_signature_results :: Field_Flags{.Ellipsis, .Using, .No_Alias, .C_Vararg, .Const, .Any_Int, .By_Ptr, .No_Broadcast, .Default_Parameters}
field_flags_signature_params :: Field_Flags {
	.Ellipsis,
	.Using,
	.No_Alias,
	.C_Vararg,
	.Const,
	.Any_Int,
	.By_Ptr,
	.No_Broadcast,
	.Default_Parameters,
	.Typeid_Token,
}

parse_type_or_ident :: proc(p: ^Parser) -> Node_Index {
	prev_allow_type := p.allow_type
	prev_expr_level := p.expr_level
	defer {
		p.allow_type = prev_allow_type
		p.expr_level = prev_expr_level
	}

	p.allow_type = true
	p.expr_level = -1

	lhs := true
	return parse_atom_expr(p, parse_operand(p, lhs), lhs)
}

parse_type :: proc(p: ^Parser) -> Node_Index {
	return parse_type_or_ident(p)
}

parse_var_type :: proc(p: ^Parser, flags: Field_Flags) -> Node_Index {
	if .Ellipsis in flags && p.curr.kind == .Ellipsis {
		tok := advance_token(p)
		type := parse_type_or_ident(p)
		return add_node(p, .Ellipsis, tok.start, p.prev.end, Ellipsis{op = .Ellipsis, expr = type})
	}
	if .Typeid_Token in flags && p.curr.kind == .Typeid {
		tok := expect_token(p, .Typeid)
		specialization: Node_Index
		if allow_token(p, .Quo) {
			specialization = parse_type(p)
		}
		return add_node(p, .Typeid_Type, tok.start, p.prev.end, Typeid_Type{specialization = specialization})
	}
	return parse_type(p)
}

// field_directive_flag maps a `#name` field prefix to its flag.
field_directive_flag :: proc(name: string) -> (flag: Field_Flag, ok: bool) {
	switch name {
	case "no_alias":
		return .No_Alias, true
	case "c_vararg":
		return .C_Vararg, true
	case "const":
		return .Const, true
	case "any_int":
		return .Any_Int, true
	case "subtype":
		return .Subtype, true
	case "by_ptr":
		return .By_Ptr, true
	case "no_broadcast":
		return .No_Broadcast, true
	case "no_capture":
		return .No_Capture, true
	}
	return {}, false
}

parse_field_prefixes :: proc(p: ^Parser) -> Field_Flags {
	counts: [Field_Flag]int
	prefix_loop: for {
		if p.curr.kind == .Using {
			advance_token(p)
			counts[.Using] += 1
			continue
		}
		if p.curr.kind != .Directive {
			break prefix_loop
		}
		name := token_text(p.tokenizer.source, p.curr)[1:]
		switch name {
		case "simd", "type", "row_major", "column_major", "sparse", "soa":
			break prefix_loop
		}
		tok := advance_token(p)
		flag, known := field_directive_flag(name)
		if !known {
			report(p, .Unknown_Directive, tok.start)
			continue
		}
		counts[flag] += 1
	}

	flags: Field_Flags
	for flag in Field_Flag {
		if counts[flag] > 1 {
			report(p, .Duplicate_Directive, p.curr.start)
		}
		if counts[flag] > 0 {
			flags += {flag}
		}
	}
	return flags
}

check_field_flag_prefixes :: proc(p: ^Parser, name_count: int, allowed_flags, set_flags: Field_Flags) -> Field_Flags {
	flags := set_flags
	if name_count > 1 && .Using in flags {
		report(p, .Invalid_Field, p.curr.start)
		flags -= {.Using}
	}
	for flag in Field_Flag {
		if flag in flags && flag not_in allowed_flags {
			report(p, .Unexpected_Prefix, p.curr.start)
			flags -= {flag}
		}
	}
	return flags
}

check_procedure_name_list :: proc(p: ^Parser, names: Node_Range) -> bool {
	list := node_list(p.ast, names)
	if len(list) == 0 {
		return false
	}

	first_is_polymorphic := p.ast.nodes[list[0]].kind == .Poly_Type
	any_polymorphic_names := first_is_polymorphic
	for name in list[1:] {
		is_polymorphic := p.ast.nodes[name].kind == .Poly_Type
		any_polymorphic_names ||= is_polymorphic
		if is_polymorphic != first_is_polymorphic {
			report(p, .Invalid_Field, p.ast.nodes[name].start)
			return any_polymorphic_names
		}
	}
	return any_polymorphic_names
}

parse_ident_list :: proc(p: ^Parser, allow_poly_names: bool) -> Node_Range {
	names := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(names)
	for {
		if allow_poly_names && p.curr.kind == .Dollar {
			tok := expect_token(p, .Dollar)
			ident := parse_ident(p)
			if is_blank_ident(p, ident) {
				report(p, .Blank_Poly_Name, p.ast.nodes[ident].start)
			}
			push(p, &names, add_node(p, .Poly_Type, tok.start, p.prev.end, Poly_Type{dollar = tok.start, type = ident}))
		} else {
			push(p, &names, parse_ident(p))
		}
		if p.curr.kind != .Comma {
			break
		}
		advance_token(p)
	}
	return ast_add_list(p.ast, names[:])
}

convert_to_ident_list :: proc(p: ^Parser, entries: []Field_Prefix_Entry, allow_poly_names: bool) -> Node_Range {
	names := make([dynamic]Node_Index, 0, len(entries), p.allocator)
	defer delete(names)
	for entry in entries {
		name := entry.expr
		start := p.ast.nodes[name].start
		#partial switch p.ast.nodes[name].kind {
		case .Ident, .Bad_Expr:
		case .Poly_Type:
			if !allow_poly_names || node_payload(p.ast, name, Poly_Type).specialization != 0 {
				report(p, .Invalid_Field, start)
			}
		case:
			report(p, .Expected_Token, start, .Ident)
			name = add_node(p, .Ident, start, start, Ident{})
		}
		push(p, &names, name)
	}
	return ast_add_list(p.ast, names[:])
}

expect_field_separator :: proc(p: ^Parser) -> bool {
	tok := p.curr
	if allow_token(p, .Comma) {
		return true
	}
	if allow_token(p, .Semicolon) {
		if !is_inserted_semicolon(tok) {
			report(p, .Expected_Token, tok.start, .Comma)
		}
		return true
	}
	return false
}

add_field :: proc(p: ^Parser, start: u32, names: Node_Range, type, default_value, tag: Node_Index, flags: Field_Flags) -> Node_Index {
	return add_node(p, .Field, start, p.prev.end, Field{names = names, type = type, default_value = default_value, tag = tag, flags = flags})
}

handle_field :: proc(p: ^Parser, seen_ellipsis: ^bool, fields: ^[dynamic]Node_Index, names: Node_Range, allowed_flags, set_flags: Field_Flags) -> bool {
	is_signature := (allowed_flags & field_flags_signature_params) == field_flags_signature_params
	any_polymorphic_names := check_procedure_name_list(p, names)
	flags := check_field_flag_prefixes(p, int(names.count), allowed_flags, set_flags)

	start := p.curr.start
	if names.count > 0 {
		start = p.ast.nodes[node_list(p.ast, names)[0]].start
	}

	type: Node_Index
	default_value: Node_Index
	tag: Node_Index

	expect_token(p, .Colon)
	if p.curr.kind != .Eq {
		type = parse_var_type(p, allowed_flags)
		if is_signature && !any_polymorphic_names && p.ast.nodes[unparen(p, type)].kind == .Typeid_Type {
			if node_payload(p.ast, unparen(p, type), Typeid_Type).specialization != 0 {
				report(p, .Invalid_Field, p.ast.nodes[type].start)
			}
		}
	}

	if allow_token(p, .Eq) {
		default_value = parse_expr(p, false)
		if .Default_Parameters not_in allowed_flags {
			report(p, .Invalid_Field, p.ast.nodes[default_value].start)
			default_value = 0
		}
	}

	if default_value != 0 && names.count > 1 {
		report(p, .Invalid_Field, p.ast.nodes[default_value].start)
	}
	if allowed_flags == field_flags_struct && default_value != 0 {
		report(p, .Invalid_Field, p.ast.nodes[default_value].start)
		default_value = 0
	}

	if type != 0 && p.ast.nodes[type].kind == .Ellipsis {
		if seen_ellipsis^ {
			report(p, .Invalid_Field, p.ast.nodes[type].start)
		}
		seen_ellipsis^ = true
		if names.count != 1 {
			report(p, .Invalid_Field, p.ast.nodes[type].start)
		}
	} else if seen_ellipsis^ && default_value == 0 {
		report(p, .Invalid_Field, p.curr.start)
	}

	if type != 0 && default_value == 0 && (p.curr.kind == .String || p.curr.kind == .Raw_String) {
		tag_tok := advance_token(p)
		tag = add_node(p, .Basic_Lit, tag_tok.start, tag_tok.end, Basic_Lit{kind = tag_tok.kind})
		if .Tags not_in allowed_flags {
			report(p, .Invalid_Field, tag_tok.start)
		}
	}

	ok := expect_field_separator(p)
	push(p, fields, add_field(p, start, names, type, default_value, tag, flags))
	return ok
}

// parse_field_list parses fields up to `closing`, which it leaves unconsumed.
parse_field_list :: proc(p: ^Parser, closing: Token_Kind, allowed_flags: Field_Flags) -> (list: Node_Index, name_count: int) {
	start := p.curr.start
	fields := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(fields)
	entries := make([dynamic]Field_Prefix_Entry, 0, 4, p.allocator)
	defer delete(entries)

	seen_ellipsis := false
	allow_poly_names := .Typeid_Token in allowed_flags

	for p.curr.kind != closing && p.curr.kind != .Colon && p.curr.kind != .EOF {
		if closing == .Close_Brace {
			enforce_tab_indentation(p)
		}
		prefix_flags := parse_field_prefixes(p)
		param := parse_var_type(p, allowed_flags & {.Typeid_Token, .Ellipsis})
		if p.ast.nodes[param].kind == .Ellipsis {
			if seen_ellipsis {
				report(p, .Invalid_Field, p.ast.nodes[param].start)
			}
			seen_ellipsis = true
		} else if seen_ellipsis {
			report(p, .Invalid_Field, p.ast.nodes[param].start)
		}
		push(p, &entries, Field_Prefix_Entry{expr = param, flags = prefix_flags})
		if !allow_token(p, .Comma) {
			break
		}
	}

	if p.curr.kind != .Colon {
		for entry in entries {
			type_start := p.ast.nodes[entry.expr].start
			name := add_node(p, .Ident, type_start, type_start, Ident{})
			names := ast_add_list(p.ast, []Node_Index{name})
			flags := check_field_flag_prefixes(p, len(entries), allowed_flags, entry.flags)
			push(p, &fields, add_field(p, type_start, names, entry.expr, 0, 0, flags))
		}
	} else {
		names := convert_to_ident_list(p, entries[:], allow_poly_names)
		if names.count == 0 {
			report(p, .Invalid_Field, p.curr.start)
		}
		set_flags: Field_Flags
		if len(entries) > 0 {
			set_flags = entries[0].flags
		}
		name_count += int(names.count)
		ok := handle_field(p, &seen_ellipsis, &fields, names, allowed_flags, set_flags)
		for ok && p.curr.kind != closing && p.curr.kind != .EOF {
			set_flags = parse_field_prefixes(p)
			if p.curr.kind == .Ellipsis {
				ellipsis_start := p.curr.start
				type := parse_var_type(p, allowed_flags)
				if seen_ellipsis {
					report(p, .Invalid_Field, p.ast.nodes[type].start)
				}
				seen_ellipsis = true
				ok = expect_field_separator(p)
				push(p, &fields, add_field(p, ellipsis_start, {}, type, 0, 0, check_field_flag_prefixes(p, 0, allowed_flags, set_flags)))
				continue
			}
			names = parse_ident_list(p, allow_poly_names)
			name_count += int(names.count)
			ok = handle_field(p, &seen_ellipsis, &fields, names, allowed_flags, set_flags)
		}
	}

	list = add_node(p, .Field_List, start, p.curr.start, Field_List{open = start, list = ast_add_list(p.ast, fields[:]), close = p.curr.start})
	return
}

parse_results :: proc(p: ^Parser) -> (list: Node_Index, diverging: bool) {
	if !allow_token(p, .Arrow_Right) {
		return
	}
	if allow_token(p, .Not) {
		diverging = true
		return
	}

	prev_level := p.expr_level
	defer p.expr_level = prev_level

	if p.curr.kind != .Open_Paren {
		start := p.curr.start
		type := parse_type(p)
		field := add_field(p, start, {}, type, 0, 0, {})
		list = add_node(p, .Field_List, start, p.prev.end, Field_List{open = start, list = ast_add_list(p.ast, []Node_Index{field}), close = p.prev.end})
		return
	}

	expect_token(p, .Open_Paren)
	list, _ = parse_field_list(p, .Close_Paren, field_flags_signature_results)
	expect_closing_token(p, .Close_Paren)
	return
}

parse_proc_tags :: proc(p: ^Parser) -> Proc_Tags {
	tags: Proc_Tags
	for p.curr.kind == .Directive {
		tok := advance_token(p)
		switch token_text(p.tokenizer.source, tok) {
		case "#bounds_check":
			tags += {.Bounds_Check}
		case "#no_bounds_check":
			tags += {.No_Bounds_Check}
		case "#type_assert":
			tags += {.Type_Assert}
		case "#no_type_assert":
			tags += {.No_Type_Assert}
		case "#optional_ok":
			tags += {.Optional_Ok}
		case "#optional_allocator_error":
			tags += {.Optional_Allocator_Error}
		}
	}
	if .Bounds_Check in tags && .No_Bounds_Check in tags {
		report(p, .Illegal_Directive_Combination, p.curr.start)
	}
	if .Type_Assert in tags && .No_Type_Assert in tags {
		report(p, .Illegal_Directive_Combination, p.curr.start)
	}
	return tags
}

parse_where_clauses :: proc(p: ^Parser) -> (where_pos: u32, clauses: Node_Range) {
	skip_possible_newline(p)
	if p.curr.kind != .Where {
		return
	}
	where_pos = expect_token(p, .Where).start
	prev_level := p.expr_level
	p.expr_level = -1
	clauses = parse_expr_list(p, false)
	p.expr_level = prev_level
	return
}

is_expr_generic :: proc(p: ^Parser, index: Node_Index) -> bool {
	if index == 0 {
		return false
	}
	#partial switch p.ast.nodes[index].kind {
	case .Typeid_Type:
		return node_payload(p.ast, index, Typeid_Type).specialization != 0
	case .Poly_Type:
		return true
	case .Call_Expr:
		call := node_payload(p.ast, index, Call_Expr)
		for argument in node_list(p.ast, call.args) {
			if is_expr_generic(p, argument) { return true }
		}
	case .Field_Value:
		return is_expr_generic(p, node_payload(p.ast, index, Field_Value).value)
	case .Proc_Type:
		return node_payload(p.ast, index, Proc_Type).generic
	case .Pointer_Type:
		return is_expr_generic(p, node_payload(p.ast, index, Pointer_Type).elem)
	case .Multi_Pointer_Type:
		return is_expr_generic(p, node_payload(p.ast, index, Multi_Pointer_Type).elem)
	case .Array_Type:
		payload := node_payload(p.ast, index, Array_Type)
		return is_expr_generic(p, payload.len) || is_expr_generic(p, payload.elem)
	case .Dynamic_Array_Type:
		return is_expr_generic(p, node_payload(p.ast, index, Dynamic_Array_Type).elem)
	case .Fixed_Capacity_Dynamic_Array_Type:
		payload := node_payload(p.ast, index, Fixed_Capacity_Dynamic_Array_Type)
		return is_expr_generic(p, payload.capacity) || is_expr_generic(p, payload.elem)
	case .Bit_Set_Type:
		return is_expr_generic(p, node_payload(p.ast, index, Bit_Set_Type).elem)
	case .Map_Type:
		payload := node_payload(p.ast, index, Map_Type)
		return is_expr_generic(p, payload.key) || is_expr_generic(p, payload.value)
	case .Matrix_Type:
		payload := node_payload(p.ast, index, Matrix_Type)
		return is_expr_generic(p, payload.row_count) || is_expr_generic(p, payload.column_count) || is_expr_generic(p, payload.elem)
	}
	return false
}

is_field_list_generic :: proc(p: ^Parser, list: Node_Index, check_names: bool) -> bool {
	for field_index in node_list(p.ast, node_payload(p.ast, list, Field_List).list) {
		field := node_payload(p.ast, field_index, Field)
		if is_expr_generic(p, field.type) {
			return true
		}
		if !check_names || field.type == 0 {
			continue
		}
		for name in node_list(p.ast, field.names) {
			if p.ast.nodes[name].kind == .Poly_Type {
				return true
			}
		}
	}
	return false
}

parse_proc_type :: proc(p: ^Parser, tok: Token) -> Node_Index {
	calling_convention: Node_Index
	if p.curr.kind == .String {
		str := expect_token(p, .String)
		if str.end - str.start == 2 {
			report(p, .Unknown_Calling_Convention, str.start)
		}
		calling_convention = add_node(p, .Basic_Lit, str.start, str.end, Basic_Lit{kind = .String})
	}
	foreign_default := calling_convention == 0 && p.in_foreign_block

	expect_token(p, .Open_Paren)
	p.expr_level += 1
	params, _ := parse_field_list(p, .Close_Paren, field_flags_signature_params)
	p.expr_level -= 1
	expect_closing_token(p, .Close_Paren)
	results, diverging := parse_results(p)

	is_generic := is_field_list_generic(p, params, true)
	if !is_generic && results != 0 {
		is_generic = is_field_list_generic(p, results, false)
	}

	return add_node(
		p,
		.Proc_Type,
		tok.start,
		p.prev.end,
		Proc_Type {
			proc_pos = tok.start,
			calling_convention = calling_convention,
			foreign_default = foreign_default,
			params = params,
			results = results,
			generic = is_generic,
			diverging = diverging,
		},
	)
}

parse_proc_group :: proc(p: ^Parser, group_tok: Token) -> Node_Index {
	open := expect_token(p, .Open_Brace)
	args := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(args)
	for p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
		elem := parse_expr(p, false)
		if p.curr.kind == .Where {
			where_tok := expect_token(p, .Where)
			cond := parse_expr(p, false)
			elem = add_node(p, .Binary_Expr, p.ast.nodes[elem].start, p.prev.end, Binary_Expr{left = elem, op = where_tok, right = cond})
		}
		push(p, &args, elem)
		if !allow_token(p, .Comma) {
			break
		}
	}
	close := expect_closing_token(p, .Close_Brace)
	if len(args) == 0 {
		report(p, .Expected_Operand, group_tok.start)
	}
	return add_node(
		p,
		.Proc_Group,
		group_tok.start,
		close.end,
		Proc_Group{proc_pos = group_tok.start, open = open.start, args = ast_add_list(p.ast, args[:]), close = close.start},
	)
}

parse_proc_expr :: proc(p: ^Parser) -> Node_Index {
	tok := expect_token(p, .Proc)

	if p.curr.kind == .Open_Brace {
		return parse_proc_group(p, tok)
	}

	type := parse_proc_type(p, tok)
	skip_possible_newline(p)
	where_pos, where_clauses := parse_where_clauses(p)
	tags := parse_proc_tags(p)
	proc_type := node_payload(p.ast, type, Proc_Type)
	proc_type.tags = tags
	p.ast.nodes[type].payload = proc_type

	if p.allow_type && p.expr_level < 0 {
		if where_pos != 0 {
			report(p, .Invalid_Proc_Signature, where_pos)
		}
		return type
	}

	skip_possible_newline(p)
	body: Node_Index
	p.proc_depth += 1
	defer p.proc_depth -= 1
	if allow_token(p, .Undef) {
	} else if p.curr.kind == .Open_Brace {
		body = parse_body(p)
	} else if allow_token(p, .Do) {
		body = parse_stmt(p)
		if newline_between(p, p.ast.nodes[type].end, p.ast.nodes[body].start) {
			report(p, .Invalid_Proc_Signature, p.ast.nodes[body].start)
		}
	} else {
		return type
	}

	return add_node(p, .Proc_Lit, tok.start, p.prev.end, Proc_Lit{type = type, body = body, tags = tags, where_pos = where_pos, where_clauses = where_clauses})
}

parse_bracket_type :: proc(p: ^Parser) -> Node_Index {
	open := expect_token(p, .Open_Bracket)
	count: Node_Index
	#partial switch p.curr.kind {
	case .Pointer:
		tok := expect_token(p, .Pointer)
		close := expect_closing(p, .Close_Bracket)
		elem := parse_type(p)
		return add_node(
			p,
			.Multi_Pointer_Type,
			open.start,
			p.prev.end,
			Multi_Pointer_Type{open = open.start, pointer = tok.start, close = close.start, elem = elem},
		)

	case .Dynamic:
		tok := expect_token(p, .Dynamic)
		if allow_token(p, .Semicolon) {
			capacity := parse_expr(p, false)
			close := expect_closing(p, .Close_Bracket)
			elem := parse_type(p)
			return add_node(
				p,
				.Fixed_Capacity_Dynamic_Array_Type,
				open.start,
				p.prev.end,
				Fixed_Capacity_Dynamic_Array_Type{open = open.start, dynamic_pos = tok.start, capacity = capacity, close = close.start, elem = elem},
			)
		}
		close := expect_closing(p, .Close_Bracket)
		elem := parse_type(p)
		return add_node(
			p,
			.Dynamic_Array_Type,
			open.start,
			p.prev.end,
			Dynamic_Array_Type{open = open.start, dynamic_pos = tok.start, close = close.start, elem = elem},
		)

	case .Question:
		tok := expect_token(p, .Question)
		count = add_node(p, .Unary_Expr, tok.start, tok.end, Unary_Expr{op = tok})

	case .Close_Bracket:

	case:
		p.expr_level += 1
		count = parse_expr(p, false)
		p.expr_level -= 1
	}

	close := expect_closing(p, .Close_Bracket)
	elem := parse_type(p)
	return add_node(p, .Array_Type, open.start, p.prev.end, Array_Type{open = open.start, len = count, close = close.start, elem = elem})
}

parse_map_type :: proc(p: ^Parser) -> Node_Index {
	tok := expect_token(p, .Map)
	expect_token(p, .Open_Bracket)
	key := parse_type(p)
	expect_closing(p, .Close_Bracket)
	value := parse_type(p)
	return add_node(p, .Map_Type, tok.start, p.prev.end, Map_Type{tok_pos = tok.start, key = key, value = value})
}

parse_poly_params :: proc(p: ^Parser) -> Node_Index {
	if !allow_token(p, .Open_Paren) {
		return 0
	}
	params, count := parse_field_list(p, .Close_Paren, field_flags_record_poly_params)
	result := params
	if count == 0 {
		report(p, .Missing_Poly_Parameter, p.ast.nodes[params].start)
		result = 0
	}
	expect_closing(p, .Close_Paren)
	return result
}

struct_tag_flag :: proc(name: string) -> (flag: Struct_Flag, ok: bool) {
	switch name {
	case "packed":
		return .Packed, true
	case "raw_union":
		return .Raw_Union, true
	case "no_copy":
		return .No_Copy, true
	case "all_or_none":
		return .All_Or_None, true
	case "simple":
		return .Simple, true
	}
	return {}, false
}

parse_struct_type :: proc(p: ^Parser) -> Node_Index {
	tok := expect_token(p, .Struct)
	poly_params := parse_poly_params(p)

	align, min_field_align, max_field_align: Node_Index
	flags: Struct_Flags
	prev_level := p.expr_level
	p.expr_level = -1
	for p.curr.kind == .Directive {
		tag := advance_token(p)
		name := token_text(p.tokenizer.source, tag)[1:]
		switch name {
		case "align":
			if align != 0 {
				report(p, .Duplicate_Directive, tag.start)
			}
			align = parse_expr(p, true)
		case "min_field_align", "field_align":
			if min_field_align != 0 {
				report(p, .Duplicate_Directive, tag.start)
			}
			min_field_align = parse_expr(p, true)
		case "max_field_align":
			if max_field_align != 0 {
				report(p, .Duplicate_Directive, tag.start)
			}
			max_field_align = parse_expr(p, true)
		case:
			flag, known := struct_tag_flag(name)
			if !known {
				report(p, .Unknown_Directive, tag.start)
			} else if flag in flags {
				report(p, .Duplicate_Directive, tag.start)
			} else {
				flags += {flag}
			}
		}
	}
	p.expr_level = prev_level

	if .Raw_Union in flags && .All_Or_None in flags {
		flags -= {.All_Or_None}
		report(p, .Illegal_Directive_Combination, tok.start)
	}

	where_pos, where_clauses := parse_where_clauses(p)
	skip_possible_newline(p)
	expect_token(p, .Open_Brace)
	fields, name_count := parse_field_list(p, .Close_Brace, field_flags_struct)
	close := expect_closing_token(p, .Close_Brace)

	return add_node(
		p,
		.Struct_Type,
		tok.start,
		close.end,
		Struct_Type {
			tok_pos = tok.start,
			poly_params = poly_params,
			align = align,
			min_field_align = min_field_align,
			max_field_align = max_field_align,
			where_pos = where_pos,
			where_clauses = where_clauses,
			fields = fields,
			name_count = u32(name_count),
			flags = flags,
		},
	)
}

parse_union_type :: proc(p: ^Parser) -> Node_Index {
	tok := expect_token(p, .Union)
	poly_params := parse_poly_params(p)

	align: Node_Index
	no_nil, shared_nil: bool
	prev_level := p.expr_level
	p.expr_level = -1
	for p.curr.kind == .Directive {
		tag := advance_token(p)
		name := token_text(p.tokenizer.source, tag)[1:]
		switch name {
		case "align":
			if align != 0 {
				report(p, .Duplicate_Directive, tag.start)
			}
			align = parse_expr(p, true)
		case "no_nil":
			if no_nil {
				report(p, .Duplicate_Directive, tag.start)
			}
			no_nil = true
		case "shared_nil":
			if shared_nil {
				report(p, .Duplicate_Directive, tag.start)
			}
			shared_nil = true
		case:
			report(p, .Unknown_Directive, tag.start)
		}
	}
	p.expr_level = prev_level

	if no_nil && shared_nil {
		report(p, .Illegal_Directive_Combination, p.curr.start)
	}
	kind := Union_Type_Kind.Normal
	if no_nil {
		kind = .No_Nil
	} else if shared_nil {
		kind = .Shared_Nil
	}

	where_pos, where_clauses := parse_where_clauses(p)
	skip_possible_newline(p)
	expect_token(p, .Open_Brace)

	variants := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(variants)
	for p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
		enforce_tab_indentation(p)
		variant := parse_type(p)
		if p.ast.nodes[variant].kind != .Bad_Expr {
			push(p, &variants, variant)
		}
		if !allow_token(p, .Comma) {
			break
		}
	}
	close := expect_closing_token(p, .Close_Brace)

	return add_node(
		p,
		.Union_Type,
		tok.start,
		close.end,
		Union_Type {
			tok_pos = tok.start,
			poly_params = poly_params,
			align = align,
			kind = kind,
			where_pos = where_pos,
			where_clauses = where_clauses,
			variants = ast_add_list(p.ast, variants[:]),
		},
	)
}

parse_enum_type :: proc(p: ^Parser) -> Node_Index {
	tok := expect_token(p, .Enum)
	base_type: Node_Index
	if p.curr.kind != .Open_Brace {
		base_type = parse_type(p)
	}

	skip_possible_newline(p)
	open := expect_token(p, .Open_Brace)
	fields := parse_elem_list(p)
	close := expect_closing_token(p, .Close_Brace)

	return add_node(
		p,
		.Enum_Type,
		tok.start,
		close.end,
		Enum_Type{tok_pos = tok.start, base_type = base_type, open = open.start, fields = fields, close = close.start},
	)
}

parse_bit_set_type :: proc(p: ^Parser) -> Node_Index {
	tok := expect_token(p, .Bit_Set)
	open := expect_token(p, .Open_Bracket)

	prev_allow_range := p.allow_range
	p.allow_range = true
	elem := parse_expr(p, false)
	p.allow_range = prev_allow_range

	underlying: Node_Index
	if allow_token(p, .Semicolon) {
		underlying = parse_type(p)
	}

	close := expect_closing(p, .Close_Bracket)
	return add_node(
		p,
		.Bit_Set_Type,
		tok.start,
		close.end,
		Bit_Set_Type{tok_pos = tok.start, open = open.start, elem = elem, underlying = underlying, close = close.start},
	)
}

parse_matrix_type :: proc(p: ^Parser) -> Node_Index {
	tok := expect_token(p, .Matrix)
	expect_token(p, .Open_Bracket)
	row_count := parse_expr(p, false)
	expect_token(p, .Comma)
	column_count := parse_expr(p, false)
	expect_closing(p, .Close_Bracket)
	elem := parse_type(p)
	return add_node(p, .Matrix_Type, tok.start, p.prev.end, Matrix_Type{tok_pos = tok.start, row_count = row_count, column_count = column_count, elem = elem})
}

parse_bit_field_type :: proc(p: ^Parser) -> Node_Index {
	tok := expect_token(p, .Bit_Field)
	backing_type := parse_type_or_ident(p)

	skip_possible_newline(p)
	open := expect_token(p, .Open_Brace)

	fields := make([dynamic]Node_Index, 0, 4, p.allocator)
	defer delete(fields)
	for p.curr.kind != .Close_Brace && p.curr.kind != .EOF {
		enforce_tab_indentation(p)
		name := parse_ident(p)
		expect_token(p, .Colon)
		type := parse_type(p)
		expect_token(p, .Or)
		bit_size := parse_expr(p, true)
		if p.curr.kind == .String || p.curr.kind == .Raw_String {
			advance_token(p)
		}
		more := allow_token(p, .Comma)
		push(p, &fields, add_node(p, .Bit_Field_Field, p.ast.nodes[name].start, p.prev.end, Bit_Field_Field{name = name, type = type, bit_size = bit_size}))
		if !more {
			break
		}
	}
	close := expect_closing_token(p, .Close_Brace)

	return add_node(
		p,
		.Bit_Field_Type,
		tok.start,
		close.end,
		Bit_Field_Type{tok_pos = tok.start, backing_type = backing_type, open = open.start, fields = ast_add_list(p.ast, fields[:]), close = close.start},
	)
}

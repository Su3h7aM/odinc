package check

import "core:strings"
import "oc:syntax"

// Renders an expression as the official expr_to_string does. Binary operators are spaced, and calls, selectors,
// slices, literals and casts are written tight. Forms outside these keep their source text.
render_expression :: proc(ast: ^syntax.Ast, source: []byte, node: syntax.Node_Index, allocator := context.temp_allocator, shorthand := false) -> string {
	builder := strings.builder_make(allocator)
	write_expression(&builder, ast, source, shorthand, node)
	return strings.to_string(builder)
}

@(private = "package")
expression_to_string :: proc(file: ^File, node: syntax.Node_Index) -> string {
	return render_expression(file.ast, file.source, node)
}

@(private = "file")
write_expression :: proc(builder: ^strings.Builder, ast: ^syntax.Ast, source: []byte, shorthand: bool, node: syntax.Node_Index) {
	if node == 0 { return }
	#partial switch ast.nodes[node].kind {
	case .Binary_Expr:
		binary := syntax.node_payload(ast, node, syntax.Binary_Expr)
		write_expression(builder, ast, source, shorthand, binary.left)
		strings.write_string(builder, " ")
		strings.write_string(builder, syntax.token_text(source, binary.op))
		strings.write_string(builder, " ")
		write_expression(builder, ast, source, shorthand, binary.right)
	case .Unary_Expr:
		unary := syntax.node_payload(ast, node, syntax.Unary_Expr)
		strings.write_string(builder, syntax.token_text(source, unary.op))
		write_expression(builder, ast, source, shorthand, unary.expr)
	case .Paren_Expr:
		strings.write_byte(builder, '(')
		write_expression(builder, ast, source, shorthand, syntax.node_payload(ast, node, syntax.Paren_Expr).expr)
		strings.write_byte(builder, ')')
	case .Selector_Expr:
		selector := syntax.node_payload(ast, node, syntax.Selector_Expr)
		write_expression(builder, ast, source, shorthand, selector.expr)
		strings.write_string(builder, syntax.token_text(source, selector.op))
		write_expression(builder, ast, source, shorthand, selector.field)
	case .Implicit_Selector_Expr:
		strings.write_byte(builder, '.')
		write_expression(builder, ast, source, shorthand, syntax.node_payload(ast, node, syntax.Implicit_Selector_Expr).field)
	case .Selector_Call_Expr:
		selector_call := syntax.node_payload(ast, node, syntax.Selector_Call_Expr)
		write_expression(builder, ast, source, shorthand, selector_call.expr)
		write_list(builder, ast, source, shorthand, syntax.node_payload(ast, selector_call.call, syntax.Call_Expr).args, "(", ")")
	case .Call_Expr:
		call := syntax.node_payload(ast, node, syntax.Call_Expr)
		if call.tailing == .Must_Tail { strings.write_string(builder, "#must_tail ") }
		if call.inlining == .Inline {
			strings.write_string(builder, "#force_inline ")
		} else if call.inlining == .No_Inline {
			strings.write_string(builder, "#force_no_inline ")
		}
		write_expression(builder, ast, source, shorthand, call.expr)
		write_list(builder, ast, source, shorthand, call.args, "(", ")")
	case .Index_Expr:
		index := syntax.node_payload(ast, node, syntax.Index_Expr)
		write_expression(builder, ast, source, shorthand, index.expr)
		strings.write_byte(builder, '[')
		write_expression(builder, ast, source, shorthand, index.index)
		strings.write_byte(builder, ']')
	case .Slice_Expr:
		slice := syntax.node_payload(ast, node, syntax.Slice_Expr)
		write_expression(builder, ast, source, shorthand, slice.expr)
		strings.write_byte(builder, '[')
		write_expression(builder, ast, source, shorthand, slice.low)
		strings.write_string(builder, syntax.token_text(source, slice.interval))
		write_expression(builder, ast, source, shorthand, slice.high)
		strings.write_byte(builder, ']')
	case .Deref_Expr:
		write_expression(builder, ast, source, shorthand, syntax.node_payload(ast, node, syntax.Deref_Expr).expr)
		strings.write_byte(builder, '^')
	case .Comp_Lit:
		literal := syntax.node_payload(ast, node, syntax.Comp_Lit)
		write_expression(builder, ast, source, shorthand, literal.type)
		write_braced(builder, ast, source, shorthand, literal.elems)
	case .Field_Value:
		field := syntax.node_payload(ast, node, syntax.Field_Value)
		write_expression(builder, ast, source, shorthand, field.field)
		strings.write_string(builder, " = ")
		write_expression(builder, ast, source, shorthand, field.value)
	case .Type_Cast:
		type_cast := syntax.node_payload(ast, node, syntax.Type_Cast)
		strings.write_string(builder, syntax.token_text(source, type_cast.token))
		strings.write_byte(builder, '(')
		write_expression(builder, ast, source, shorthand, type_cast.type)
		strings.write_byte(builder, ')')
		write_expression(builder, ast, source, shorthand, type_cast.expr)
	case .Auto_Cast:
		conversion := syntax.node_payload(ast, node, syntax.Auto_Cast)
		strings.write_string(builder, syntax.token_text(source, conversion.op))
		strings.write_byte(builder, ' ')
		write_expression(builder, ast, source, shorthand, conversion.expr)
	case .Matrix_Index_Expr:
		indexed := syntax.node_payload(ast, node, syntax.Matrix_Index_Expr)
		write_expression(builder, ast, source, shorthand, indexed.expr)
		strings.write_byte(builder, '[')
		write_expression(builder, ast, source, shorthand, indexed.row_index)
		strings.write_string(builder, ", ")
		write_expression(builder, ast, source, shorthand, indexed.column_index)
		strings.write_byte(builder, ']')
	case .Ternary_If_Expr:
		ternary := syntax.node_payload(ast, node, syntax.Ternary_Expr)
		if ast.nodes[ternary.x].start < ast.nodes[ternary.cond].start {
			write_expression(builder, ast, source, shorthand, ternary.x)
			strings.write_string(builder, " if ")
			write_expression(builder, ast, source, shorthand, ternary.cond)
			strings.write_string(builder, " else ")
		} else {
			write_expression(builder, ast, source, shorthand, ternary.cond)
			strings.write_string(builder, " ? ")
			write_expression(builder, ast, source, shorthand, ternary.x)
			strings.write_string(builder, " : ")
		}
		write_expression(builder, ast, source, shorthand, ternary.y)
	case .Ternary_When_Expr:
		ternary := syntax.node_payload(ast, node, syntax.Ternary_Expr)
		write_expression(builder, ast, source, shorthand, ternary.x)
		strings.write_string(builder, " when ")
		write_expression(builder, ast, source, shorthand, ternary.cond)
		strings.write_string(builder, " else ")
		write_expression(builder, ast, source, shorthand, ternary.y)
	case .Or_Else_Expr:
		fallback := syntax.node_payload(ast, node, syntax.Or_Else_Expr)
		write_expression(builder, ast, source, shorthand, fallback.x)
		strings.write_string(builder, " or_else ")
		write_expression(builder, ast, source, shorthand, fallback.y)
	case .Or_Return_Expr:
		write_expression(builder, ast, source, shorthand, syntax.node_payload(ast, node, syntax.Or_Return_Expr).expr)
		strings.write_string(builder, " or_return")
	case .Or_Branch_Expr:
		branch := syntax.node_payload(ast, node, syntax.Or_Branch_Expr)
		write_expression(builder, ast, source, shorthand, branch.expr)
		strings.write_byte(builder, ' ')
		strings.write_string(builder, syntax.token_text(source, branch.token))
		if branch.label != 0 {
			strings.write_byte(builder, ' ')
			write_expression(builder, ast, source, shorthand, branch.label)
		}
	case .Type_Assertion:
		assertion := syntax.node_payload(ast, node, syntax.Type_Assertion)
		write_expression(builder, ast, source, shorthand, assertion.expr)
		if assertion.type != 0 &&
		   ast.nodes[assertion.type].kind == .Unary_Expr &&
		   syntax.node_payload(ast, assertion.type, syntax.Unary_Expr).op.kind == .Question {
			strings.write_string(builder, ".?")
		} else {
			strings.write_string(builder, ".(")
			write_expression(builder, ast, source, shorthand, assertion.type)
			strings.write_byte(builder, ')')
		}
	case .Tag_Expr:
		tag := syntax.node_payload(ast, node, syntax.Tag_Expr)
		strings.write_byte(builder, '#')
		strings.write_string(builder, syntax.token_text(source, tag.op))
		write_expression(builder, ast, source, shorthand, tag.expr)
	case .Ellipsis:
		strings.write_string(builder, "..")
		write_expression(builder, ast, source, shorthand, syntax.node_payload(ast, node, syntax.Ellipsis).expr)
	case .Undef:
		strings.write_string(builder, "---")
	case .Helper_Type:
		strings.write_string(builder, "#type ")
		write_expression(builder, ast, source, shorthand, syntax.node_payload(ast, node, syntax.Helper_Type).type)
	case .Distinct_Type:
		strings.write_string(builder, "distinct ")
		write_expression(builder, ast, source, shorthand, syntax.node_payload(ast, node, syntax.Distinct_Type).type)
	case .Poly_Type:
		poly := syntax.node_payload(ast, node, syntax.Poly_Type)
		strings.write_byte(builder, '$')
		write_expression(builder, ast, source, shorthand, poly.type)
		if poly.specialization != 0 {
			strings.write_byte(builder, '/')
			write_expression(builder, ast, source, shorthand, poly.specialization)
		}
	case .Pointer_Type:
		pointer := syntax.node_payload(ast, node, syntax.Pointer_Type)
		write_expression(builder, ast, source, false, pointer.tag)
		strings.write_byte(builder, '^')
		write_expression(builder, ast, source, shorthand, pointer.elem)
	case .Multi_Pointer_Type:
		strings.write_string(builder, "[^]")
		write_expression(builder, ast, source, shorthand, syntax.node_payload(ast, node, syntax.Multi_Pointer_Type).elem)
	case .Array_Type:
		array := syntax.node_payload(ast, node, syntax.Array_Type)
		write_expression(builder, ast, source, false, array.tag)
		strings.write_byte(builder, '[')
		if array.len != 0 && ast.nodes[array.len].kind == .Unary_Expr && syntax.node_payload(ast, array.len, syntax.Unary_Expr).op.kind == .Question {
			strings.write_byte(builder, '?')
		} else {
			write_expression(builder, ast, source, shorthand, array.len)
		}
		strings.write_byte(builder, ']')
		write_expression(builder, ast, source, shorthand, array.elem)
	case .Dynamic_Array_Type:
		array := syntax.node_payload(ast, node, syntax.Dynamic_Array_Type)
		write_expression(builder, ast, source, false, array.tag)
		strings.write_string(builder, "[dynamic]")
		write_expression(builder, ast, source, shorthand, array.elem)
	case .Fixed_Capacity_Dynamic_Array_Type:
		array := syntax.node_payload(ast, node, syntax.Fixed_Capacity_Dynamic_Array_Type)
		write_expression(builder, ast, source, false, array.tag)
		strings.write_string(builder, "[dynamic; ")
		write_expression(builder, ast, source, false, array.capacity)
		strings.write_byte(builder, ']')
		write_expression(builder, ast, source, shorthand, array.elem)
	case .Bit_Set_Type:
		strings.write_string(builder, "bit_set[")
		write_expression(builder, ast, source, shorthand, syntax.node_payload(ast, node, syntax.Bit_Set_Type).elem)
		strings.write_byte(builder, ']')
	case .Map_Type:
		map_type := syntax.node_payload(ast, node, syntax.Map_Type)
		strings.write_string(builder, "map[")
		write_expression(builder, ast, source, shorthand, map_type.key)
		strings.write_byte(builder, ']')
		write_expression(builder, ast, source, shorthand, map_type.value)
	case .Matrix_Type:
		matrix_type := syntax.node_payload(ast, node, syntax.Matrix_Type)
		strings.write_string(builder, "matrix[")
		write_expression(builder, ast, source, shorthand, matrix_type.row_count)
		strings.write_string(builder, ", ")
		write_expression(builder, ast, source, shorthand, matrix_type.column_count)
		strings.write_byte(builder, ']')
		write_expression(builder, ast, source, shorthand, matrix_type.elem)
	case .Field:
		write_field(builder, ast, source, shorthand, node)
	case .Field_List:
		write_field_list(builder, ast, source, shorthand, node)
	case .Bit_Field_Field:
		field := syntax.node_payload(ast, node, syntax.Bit_Field_Field)
		write_expression(builder, ast, source, shorthand, field.name)
		strings.write_string(builder, ": ")
		write_expression(builder, ast, source, shorthand, field.type)
		strings.write_string(builder, " | ")
		write_expression(builder, ast, source, shorthand, field.bit_size)
	case .Proc_Type:
		procedure := syntax.node_payload(ast, node, syntax.Proc_Type)
		strings.write_string(builder, "proc(")
		write_expression(builder, ast, source, shorthand, procedure.params)
		strings.write_byte(builder, ')')
		if procedure.results != 0 {
			strings.write_string(builder, " -> ")
			parenthesize := false
			if ast.nodes[procedure.results].kind == .Field_List {
				for result in syntax.node_list(ast, syntax.node_payload(ast, procedure.results, syntax.Field_List).list) {
					if syntax.node_payload(ast, result, syntax.Field).names.count != 0 { parenthesize = true }
				}
			}
			if parenthesize { strings.write_byte(builder, '(') }
			write_expression(builder, ast, source, shorthand, procedure.results)
			if parenthesize { strings.write_byte(builder, ')') }
		}
	case .Struct_Type:
		record := syntax.node_payload(ast, node, syntax.Struct_Type)
		strings.write_string(builder, "struct ")
		write_polymorphic_parameters(builder, ast, source, shorthand, record.poly_params)
		if .Packed in record.flags { strings.write_string(builder, "#packed ") }
		if .Raw_Union in record.flags { strings.write_string(builder, "#raw_union ") }
		if .All_Or_None in record.flags { strings.write_string(builder, "#all_or_none ") }
		if .Simple in record.flags { strings.write_string(builder, "#simple ") }
		write_alignment(builder, ast, source, shorthand, record.align)
		if shorthand {
			strings.write_string(builder, "{...}")
		} else {
			strings.write_byte(builder, '{')
			if record.fields != 0 {
				write_list(builder, ast, source, false, syntax.node_payload(ast, record.fields, syntax.Field_List).list, "", "")
			}
			strings.write_byte(builder, '}')
		}
	case .Union_Type:
		union_type := syntax.node_payload(ast, node, syntax.Union_Type)
		strings.write_string(builder, "union ")
		write_polymorphic_parameters(builder, ast, source, shorthand, union_type.poly_params)
		#partial switch union_type.kind {
		case .No_Nil:
			strings.write_string(builder, "#no_nil ")
		case .Shared_Nil:
			strings.write_string(builder, "#shared_nil ")
		}
		write_alignment(builder, ast, source, shorthand, union_type.align)
		write_braced(builder, ast, source, shorthand, union_type.variants)
	case .Enum_Type:
		enum_type := syntax.node_payload(ast, node, syntax.Enum_Type)
		strings.write_string(builder, "enum ")
		if enum_type.base_type != 0 {
			write_expression(builder, ast, source, shorthand, enum_type.base_type)
			strings.write_byte(builder, ' ')
		}
		write_braced(builder, ast, source, shorthand, enum_type.fields)
	case .Bit_Field_Type:
		layout := syntax.node_payload(ast, node, syntax.Bit_Field_Type)
		strings.write_string(builder, "bit_field ")
		if !shorthand { write_expression(builder, ast, source, shorthand, layout.backing_type) }
		strings.write_byte(builder, ' ')
		write_braced(builder, ast, source, shorthand, layout.fields)
	case .Relative_Type:
		relative := syntax.node_payload(ast, node, syntax.Relative_Type)
		write_expression(builder, ast, source, shorthand, relative.tag)
		write_expression(builder, ast, source, shorthand, relative.type)
	case .Typeid_Type:
		strings.write_string(builder, "typeid")
		if specialization := syntax.node_payload(ast, node, syntax.Typeid_Type).specialization; specialization != 0 {
			strings.write_byte(builder, '/')
			write_expression(builder, ast, source, shorthand, specialization)
		}
	case:
		span := ast.nodes[node]
		strings.write_string(builder, string(source[span.start:span.end]))
	}
}

@(private = "file")
write_list :: proc(builder: ^strings.Builder, ast: ^syntax.Ast, source: []byte, shorthand: bool, range: syntax.Node_Range, open, close: string) {
	strings.write_string(builder, open)
	for element, position in syntax.node_list(ast, range) {
		if position > 0 { strings.write_string(builder, ", ") }
		write_expression(builder, ast, source, shorthand, element)
	}
	strings.write_string(builder, close)
}

@(private = "file")
write_polymorphic_parameters :: proc(builder: ^strings.Builder, ast: ^syntax.Ast, source: []byte, shorthand: bool, params: syntax.Node_Index) {
	if params == 0 { return }
	strings.write_byte(builder, '(')
	write_expression(builder, ast, source, shorthand, params)
	strings.write_string(builder, ") ")
}

@(private = "file")
write_alignment :: proc(builder: ^strings.Builder, ast: ^syntax.Ast, source: []byte, shorthand: bool, align: syntax.Node_Index) {
	if align == 0 { return }
	strings.write_string(builder, "#align ")
	write_expression(builder, ast, source, shorthand, align)
	strings.write_byte(builder, ' ')
}

@(private = "file")
write_field_flags :: proc(builder: ^strings.Builder, flags: syntax.Field_Flags) {
	if .Using in flags { strings.write_string(builder, "using ") }
	if .No_Alias in flags { strings.write_string(builder, "#no_alias ") }
	if .C_Vararg in flags { strings.write_string(builder, "#c_vararg ") }
	if .Any_Int in flags { strings.write_string(builder, "#any_int ") }
	if .No_Broadcast in flags { strings.write_string(builder, "#no_broadcast ") }
	if .Const in flags { strings.write_string(builder, "#const ") }
	if .Subtype in flags { strings.write_string(builder, "#subtype ") }
}

@(private = "file")
write_field :: proc(builder: ^strings.Builder, ast: ^syntax.Ast, source: []byte, shorthand: bool, node: syntax.Node_Index) {
	field := syntax.node_payload(ast, node, syntax.Field)
	write_field_flags(builder, field.flags)
	write_list(builder, ast, source, shorthand, field.names, "", "")
	if field.names.count > 0 {
		if field.type == 0 && field.default_value != 0 { strings.write_byte(builder, ' ') }
		strings.write_byte(builder, ':')
	}
	if field.type != 0 {
		strings.write_byte(builder, ' ')
		write_expression(builder, ast, source, shorthand, field.type)
	}
	if field.default_value != 0 {
		if field.type != 0 { strings.write_byte(builder, ' ') }
		strings.write_string(builder, "= ")
		write_expression(builder, ast, source, shorthand, field.default_value)
	}
}

@(private = "file")
write_field_list :: proc(builder: ^strings.Builder, ast: ^syntax.Ast, source: []byte, shorthand: bool, node: syntax.Node_Index) {
	fields := syntax.node_list(ast, syntax.node_payload(ast, node, syntax.Field_List).list)
	has_name := false
	for candidate in fields {
		names := syntax.node_payload(ast, candidate, syntax.Field).names
		if names.count > 1 {
			has_name = true
			break
		}
		if names.count == 0 { continue }
		first := syntax.node_list(ast, names)[0]
		if ast.nodes[first].kind != .Ident || ast.nodes[first].end - ast.nodes[first].start != 1 || source[ast.nodes[first].start] != '_' {
			has_name = true
			break
		}
	}
	for candidate, position in fields {
		if position > 0 { strings.write_string(builder, ", ") }
		if has_name {
			write_field(builder, ast, source, shorthand, candidate)
		} else {
			field := syntax.node_payload(ast, candidate, syntax.Field)
			write_field_flags(builder, field.flags)
			write_expression(builder, ast, source, shorthand, field.type)
		}
	}
}

// A braced list; the abbreviated form hides the elements.
@(private = "file")
write_braced :: proc(builder: ^strings.Builder, ast: ^syntax.Ast, source: []byte, shorthand: bool, range: syntax.Node_Range) {
	if shorthand {
		strings.write_string(builder, "{...}")
	} else {
		write_list(builder, ast, source, false, range, "{", "}")
	}
}

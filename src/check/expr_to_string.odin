package check

import "core:strings"
import "oc:syntax"

// Renders an expression as the official expr_to_string does. Binary operators are spaced, and calls, selectors,
// slices, literals and casts are written tight. Forms outside these keep their source text.
@(private = "package")
expression_to_string :: proc(file: ^File, node: syntax.Node_Index) -> string {
	builder := strings.builder_make(context.temp_allocator)
	write_expression(&builder, file, node)
	return strings.to_string(builder)
}

@(private = "file")
write_expression :: proc(builder: ^strings.Builder, file: ^File, node: syntax.Node_Index) {
	if node == 0 { return }
	ast := file.ast
	#partial switch ast.nodes[node].kind {
	case .Binary_Expr:
		binary := syntax.node_payload(ast, node, syntax.Binary_Expr)
		write_expression(builder, file, binary.left)
		strings.write_string(builder, " ")
		strings.write_string(builder, syntax.token_text(file.source, binary.op))
		strings.write_string(builder, " ")
		write_expression(builder, file, binary.right)
	case .Unary_Expr:
		unary := syntax.node_payload(ast, node, syntax.Unary_Expr)
		strings.write_string(builder, syntax.token_text(file.source, unary.op))
		write_expression(builder, file, unary.expr)
	case .Paren_Expr:
		strings.write_byte(builder, '(')
		write_expression(builder, file, syntax.node_payload(ast, node, syntax.Paren_Expr).expr)
		strings.write_byte(builder, ')')
	case .Selector_Expr:
		selector := syntax.node_payload(ast, node, syntax.Selector_Expr)
		write_expression(builder, file, selector.expr)
		strings.write_string(builder, syntax.token_text(file.source, selector.op))
		write_expression(builder, file, selector.field)
	case .Implicit_Selector_Expr:
		strings.write_byte(builder, '.')
		write_expression(builder, file, syntax.node_payload(ast, node, syntax.Implicit_Selector_Expr).field)
	case .Selector_Call_Expr:
		selector_call := syntax.node_payload(ast, node, syntax.Selector_Call_Expr)
		write_expression(builder, file, selector_call.expr)
		write_list(builder, file, syntax.node_payload(ast, selector_call.call, syntax.Call_Expr).args, "(", ")")
	case .Call_Expr:
		call := syntax.node_payload(ast, node, syntax.Call_Expr)
		if call.tailing == .Must_Tail { strings.write_string(builder, "#must_tail ") }
		if call.inlining == .Inline {
			strings.write_string(builder, "#force_inline ")
		} else if call.inlining == .No_Inline {
			strings.write_string(builder, "#force_no_inline ")
		}
		write_expression(builder, file, call.expr)
		write_list(builder, file, call.args, "(", ")")
	case .Index_Expr:
		index := syntax.node_payload(ast, node, syntax.Index_Expr)
		write_expression(builder, file, index.expr)
		strings.write_byte(builder, '[')
		write_expression(builder, file, index.index)
		strings.write_byte(builder, ']')
	case .Slice_Expr:
		slice := syntax.node_payload(ast, node, syntax.Slice_Expr)
		write_expression(builder, file, slice.expr)
		strings.write_byte(builder, '[')
		write_expression(builder, file, slice.low)
		strings.write_string(builder, syntax.token_text(file.source, slice.interval))
		write_expression(builder, file, slice.high)
		strings.write_byte(builder, ']')
	case .Deref_Expr:
		write_expression(builder, file, syntax.node_payload(ast, node, syntax.Deref_Expr).expr)
		strings.write_byte(builder, '^')
	case .Comp_Lit:
		literal := syntax.node_payload(ast, node, syntax.Comp_Lit)
		write_expression(builder, file, literal.type)
		write_list(builder, file, literal.elems, "{", "}")
	case .Field_Value:
		field := syntax.node_payload(ast, node, syntax.Field_Value)
		write_expression(builder, file, field.field)
		strings.write_string(builder, " = ")
		write_expression(builder, file, field.value)
	case .Type_Cast:
		type_cast := syntax.node_payload(ast, node, syntax.Type_Cast)
		strings.write_string(builder, syntax.token_text(file.source, type_cast.token))
		strings.write_byte(builder, '(')
		write_expression(builder, file, type_cast.type)
		strings.write_byte(builder, ')')
		write_expression(builder, file, type_cast.expr)
	case .Auto_Cast:
		conversion := syntax.node_payload(ast, node, syntax.Auto_Cast)
		strings.write_string(builder, syntax.token_text(file.source, conversion.op))
		strings.write_byte(builder, ' ')
		write_expression(builder, file, conversion.expr)
	case:
		strings.write_string(builder, expression_text(file, node))
	}
}

@(private = "file")
write_list :: proc(builder: ^strings.Builder, file: ^File, range: syntax.Node_Range, open, close: string) {
	strings.write_string(builder, open)
	for element, position in syntax.node_list(file.ast, range) {
		if position > 0 { strings.write_string(builder, ", ") }
		write_expression(builder, file, element)
	}
	strings.write_string(builder, close)
}
